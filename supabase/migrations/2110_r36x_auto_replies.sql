-- 2110_r36x_auto_replies.sql
-- Release 36, helper X, task 2. The owner: "free AI auto-replies to FAQ questions across SMS (Quo inbound), email, website
-- live chat, WhatsApp, Messenger and Instagram where the platform has an inbound path: Cloudflare Workers AI free tier (hard
-- stop at the free allowance; fall back to no auto-reply), answer only from the FAQ/knowledge base, hand off to staff when
-- unsure, respect renter SMS quiet hours 1-5 am. Settings per channel (on by default where an inbound path exists)."
--   1. Program settings (group "AI auto-replies"): auto_reply_sms, _email, _chat, _whatsapp, _messenger, _instagram (on);
--      the quiet hours of texts (1 to 5, Toronto: a reply asked for then waits until 5), the replies one sender may get a
--      day (5), how sure the model must be (70%), the model (the small Workers AI one), the email inboxes answered ("help"),
--      what a handed-off sender is told (empty: nothing), the Meta webhook's verify token and the WhatsApp number id.
--   2. auto_replies: every question seen and what was done (sent, queued for the end of the quiet hours, handed off,
--      skipped and why), with the neurons spent (recorded in provider_calls as faq_reply, a live feature of 0133's tiers).
--   3. public.server_auto_reply_gate {channel, sender}: may the site answer this one? The channel on, the sender's
--      replies of the day under the cap, a person not already talking with them (a staff text in the last 2 hours), not
--      opted out, and Workers AI with room in the free allowance (app.ai_budget: paused, or the live room under 400
--      neurons: no). The Worker treats any failure of the gate as "no" (fail closed: never past the free tier).
--   4. public.server_auto_reply_record {channel, sender, question, answer, confident, ...}: an answer the model was sure of
--      is sent (a text through the phone outbox, kind auto_reply, held until the quiet hours end; other channels by the
--      Worker); anything else is handed off: for texts the conversation is already in Messages, for email and Meta a To do
--      for customer service ("Answer: <question>"), deduplicated by sender and day.
-- The website's live chat keeps its own assistant (0060, 0370), which answers from the same facts; auto_reply_chat switches
-- it (with chat_ai_enabled, both must be on).
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

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists auto_reply_sms boolean not null default true,
  add column if not exists auto_reply_email boolean not null default true,
  add column if not exists auto_reply_chat boolean not null default true,
  add column if not exists auto_reply_whatsapp boolean not null default true,
  add column if not exists auto_reply_messenger boolean not null default true,
  add column if not exists auto_reply_instagram boolean not null default true,
  add column if not exists auto_reply_quiet_from_hour integer not null default 1 check (auto_reply_quiet_from_hour between 0 and 23),
  add column if not exists auto_reply_quiet_until_hour integer not null default 5 check (auto_reply_quiet_until_hour between 0 and 23),
  add column if not exists auto_reply_per_sender_day integer not null default 5 check (auto_reply_per_sender_day between 0 and 50),
  add column if not exists auto_reply_min_confidence_bps integer not null default 7000 check (auto_reply_min_confidence_bps between 0 and 10000),
  add column if not exists auto_reply_model text not null default '@cf/meta/llama-3.1-8b-instruct-fp8-fast' check (auto_reply_model ~ '^@cf/[a-z0-9._/-]{3,100}$'),
  add column if not exists auto_reply_email_inboxes text not null default 'help' check (auto_reply_email_inboxes ~ '^[a-z0-9._+-]+(\s*,\s*[a-z0-9._+-]+)*$'),
  add column if not exists auto_reply_handoff_text text not null default '' check (length(auto_reply_handoff_text) <= 300),
  add column if not exists auto_reply_meta_verify_token text not null default replace(gen_random_uuid()::text, '-', '') check (auto_reply_meta_verify_token ~ '^[A-Za-z0-9_-]{16,80}$'),
  add column if not exists auto_reply_whatsapp_phone_id text check (auto_reply_whatsapp_phone_id is null or auto_reply_whatsapp_phone_id ~ '^[0-9]{5,30}$');
comment on column program_settings.auto_reply_sms is 'AI auto-replies (2110): answer FAQ questions texted to the CarmaCars number (Quo) from the FAQ only, within the free Workers AI allowance; unsure: staff answer in Messages.';
comment on column program_settings.auto_reply_email is 'AI auto-replies (2110): answer FAQ questions emailed to the inboxes below (the Worker''s email route of in.carmacars.ca).';
comment on column program_settings.auto_reply_chat is 'AI auto-replies (2110): the website live chat''s assistant (0060) answers; off: staff answer every chat.';
comment on column program_settings.auto_reply_whatsapp is 'AI auto-replies (2110): WhatsApp messages (Meta webhook; needs the WhatsApp number id below and the WHATSAPP_TOKEN secret).';
comment on column program_settings.auto_reply_messenger is 'AI auto-replies (2110): Facebook Page messages (Meta webhook, the Page token of Meta publishing).';
comment on column program_settings.auto_reply_instagram is 'AI auto-replies (2110): Instagram direct messages (Meta webhook, the Page token of Meta publishing).';
comment on column program_settings.auto_reply_quiet_from_hour is 'AI auto-replies (2110): texts asked for from this Toronto hour wait (1 is 1 am).';
comment on column program_settings.auto_reply_quiet_until_hour is 'AI auto-replies (2110): ... until this hour (5 is 5 am), then they are sent.';
comment on column program_settings.auto_reply_per_sender_day is 'AI auto-replies (2110): the most automatic answers one sender gets a day (then staff).';
comment on column program_settings.auto_reply_min_confidence_bps is 'AI auto-replies (2110): how sure the model must be that the FAQ answers the question (70%); less: handed to staff.';
comment on column program_settings.auto_reply_model is 'AI auto-replies (2110): the Workers AI model (the small one keeps within the free allowance).';
comment on column program_settings.auto_reply_email_inboxes is 'AI auto-replies (2110): the inboxes answered, before the @ (help: help@in.carmacars.ca routed to the Worker).';
comment on column program_settings.auto_reply_handoff_text is 'AI auto-replies (2110): what a sender is told when a person will answer (empty: nothing is sent).';
comment on column program_settings.auto_reply_meta_verify_token is 'AI auto-replies (2110): the verify token to paste into the Meta app''s webhook (Messenger, Instagram, WhatsApp): https://carmacars.ca/api/webhooks/meta.';
comment on column program_settings.auto_reply_whatsapp_phone_id is 'AI auto-replies (2110): the WhatsApp Business phone number id (Meta); empty: WhatsApp is not answered.';

alter table phone_outbox drop constraint if exists phone_outbox_kind_check;
alter table phone_outbox add constraint phone_outbox_kind_check check (kind in ('missed_call', 'booking', 'staff', 'notify', 'opt_confirm', 'auto_reply'));

-- the feature in the AI budget's tiers (0133): a live feature, with its name on Settings > Usage
alter function app.ai_tier(text) rename to ai_tier_pre2110;
create function app.ai_tier(p_purpose text) returns text
language sql immutable as $$ select case when p_purpose = 'faq_reply' then 'live' else app.ai_tier_pre2110(p_purpose) end $$;
select pg_temp.copy_grants('app.ai_tier(text)'::regprocedure, 'app.ai_tier_pre2110(text)'::regprocedure);
alter function app.ai_feature_label(text) rename to ai_feature_label_pre2110;
create function app.ai_feature_label(p_purpose text) returns text
language sql immutable as $$ select case when p_purpose = 'faq_reply' then 'FAQ auto-replies' else app.ai_feature_label_pre2110(p_purpose) end $$;
select pg_temp.copy_grants('app.ai_feature_label(text)'::regprocedure, 'app.ai_feature_label_pre2110(text)'::regprocedure);

-- ================================================================ 2. the log
create table if not exists auto_replies (
  id          uuid primary key default gen_random_uuid(),
  channel     text not null check (channel in ('sms', 'email', 'chat', 'whatsapp', 'messenger', 'instagram')),
  sender      text not null check (length(sender) between 1 and 200),
  question    text check (length(question) <= 1000),
  answer      text check (length(answer) <= 1600),
  status      text not null check (status in ('sent', 'queued', 'handoff', 'skipped', 'failed')),
  reason      text check (length(reason) <= 300),
  faq         text[] not null default '{}',
  neurons     integer not null default 0,
  model       text,
  outbox_id   uuid references phone_outbox (id) on delete set null,
  task_id     uuid,
  created_at  timestamptz not null default now()
);
comment on table auto_replies is 'AI auto-replies (2110): every question the site saw on a channel and what it did: sent (an FAQ answer), queued (a text held for the quiet hours), handoff (to staff), skipped (off, the cap, a person already talking, the free allowance used) or failed.';
create index if not exists auto_replies_sender_day on auto_replies (channel, sender, created_at desc);
alter table auto_replies enable row level security;
create policy staff_read on auto_replies for select to authenticated using (app.is_admin() or app.is_staff());
revoke all on auto_replies from public, anon, authenticated;
grant select on auto_replies to authenticated;
grant all on auto_replies to service_role;

-- ================================================================ 3. the gate
-- the end of the auto-reply quiet hours (1 to 5 Toronto by default), or now when outside them
create or replace function app.auto_reply_quiet_end(p_now timestamptz default now()) returns timestamptz
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  h integer := app.local_hour(p_now);
  q boolean;
begin
  if s.auto_reply_quiet_from_hour = s.auto_reply_quiet_until_hour then return p_now; end if;
  q := case when s.auto_reply_quiet_from_hour > s.auto_reply_quiet_until_hour then h >= s.auto_reply_quiet_from_hour or h < s.auto_reply_quiet_until_hour
            else h >= s.auto_reply_quiet_from_hour and h < s.auto_reply_quiet_until_hour end;
  if not q then return p_now; end if;
  return ((app.local_date(p_now) + case when h >= s.auto_reply_quiet_until_hour then 1 else 0 end)::timestamp
          + make_interval(hours => s.auto_reply_quiet_until_hour)) at time zone s.timezone;
end $$;

create or replace function app.auto_reply_on(p_channel text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select case p_channel when 'sms' then s.auto_reply_sms when 'email' then s.auto_reply_email when 'chat' then s.auto_reply_chat
                        when 'whatsapp' then s.auto_reply_whatsapp and s.auto_reply_whatsapp_phone_id is not null
                        when 'messenger' then s.auto_reply_messenger when 'instagram' then s.auto_reply_instagram else false end
    from (select (app.settings()).*) s
$$;

create or replace function public.server_auto_reply_gate(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_channel text := p ->> 'channel';
  v_sender text := left(btrim(coalesce(p ->> 'sender', '')), 200);
  v_b jsonb;
  t phone_threads;
  no jsonb;
begin
  no := jsonb_build_object('allowed', false);
  if v_channel is null or v_channel not in ('sms', 'email', 'chat', 'whatsapp', 'messenger', 'instagram') then return no || jsonb_build_object('reason', 'unknown channel'); end if;
  if not app.auto_reply_on(v_channel) then return no || jsonb_build_object('reason', 'off in Program settings'); end if;
  if v_sender = '' then return no || jsonb_build_object('reason', 'no sender'); end if;
  if (select count(*) from auto_replies a where a.channel = v_channel and a.sender = v_sender and a.status in ('sent', 'queued')
        and a.created_at >= app.local_midnight(app.local_date(now()))) >= s.auto_reply_per_sender_day then
    return no || jsonb_build_object('reason', 'the sender''s automatic answers of the day are used');
  end if;
  if v_channel = 'sms' then
    select * into t from phone_threads where number = v_sender;
    if t.opted_out_at is not null then return no || jsonb_build_object('reason', 'the number opted out of texts'); end if;
    if not s.phone_enabled then return no || jsonb_build_object('reason', 'phone and texts are off'); end if;
    if exists (select 1 from phone_outbox o where o.to_number = v_sender and o.kind = 'staff' and o.created_at > now() - interval '2 hours') then
      return no || jsonb_build_object('reason', 'a person is talking with them');
    end if;
    if exists (select 1 from users u where u.phone = v_sender and app.user_is_staff(u.id)) then return no || jsonb_build_object('reason', 'a staff number'); end if;
  end if;
  -- the free allowance: Workers AI paused for the day, or too little room left for live features: no automatic answer
  v_b := app.ai_budget();
  if v_b is null or coalesce((v_b ->> 'paused')::boolean, false) or coalesce((v_b #>> '{room,live}')::numeric, 0) < 400 then
    return no || jsonb_build_object('reason', 'the free Workers AI allowance of the day is used');
  end if;
  return jsonb_build_object('allowed', true, 'model', s.auto_reply_model, 'min_confidence', s.auto_reply_min_confidence_bps / 10000.0,
    'handoff_text', nullif(s.auto_reply_handoff_text, ''), 'brand', coalesce((select ss.brand_name from site_settings ss limit 1), 'CarmaCars'));
end $$;

-- ================================================================ 4. the record (and the text)
create or replace function public.server_auto_reply_record(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_channel text := p ->> 'channel';
  v_sender text := left(btrim(coalesce(p ->> 'sender', '')), 200);
  v_q text := left(btrim(coalesce(p ->> 'question', '')), 1000);
  v_a text := left(btrim(coalesce(p ->> 'answer', '')), 1600);
  v_sure boolean := coalesce((p ->> 'confident')::boolean, false) and coalesce((p ->> 'confidence')::numeric, 0) >= s.auto_reply_min_confidence_bps / 10000.0;
  v_neurons integer := greatest(0, coalesce((p ->> 'neurons')::integer, 0));
  v_status text;
  v_reason text := left(p ->> 'reason', 300);
  v_when timestamptz;
  o phone_outbox;
  v_task uuid;
  v_id uuid;
  v_send jsonb := '[]'::jsonb;
begin
  if v_channel is null or v_channel not in ('sms', 'email', 'chat', 'whatsapp', 'messenger', 'instagram') then raise exception 'Unknown channel' using errcode = '22023'; end if;
  if nullif(p ->> 'model', '') is not null then
    insert into provider_calls (provider, purpose, ok, error, duration_ms, cost_microusd, units, unit)
    values ('workers-ai', 'faq_reply', coalesce((p ->> 'ok')::boolean, v_a <> ''), left(p ->> 'error', 300), greatest(0, coalesce((p ->> 'duration_ms')::integer, 0)), 0, v_neurons, 'neurons');
  end if;
  if coalesce(p ->> 'status', '') = 'skipped' then
    v_status := 'skipped';
  elsif v_a <> '' and v_sure then
    if v_channel = 'sms' then
      v_when := app.auto_reply_quiet_end(now());
      o := app.phone_outbox_put(v_sender, v_a, 'auto_reply', p_send_after => v_when, p_status => case when v_when <= now() then 'sending' else 'queued' end);
      v_status := case when o.status = 'skipped' then 'skipped' when o.status = 'sending' then 'sent' else 'queued' end;
      v_reason := coalesce(o.status_reason, case when v_status = 'queued' then 'held for the quiet hours' end, v_reason);
      if o.status = 'sending' then v_send := jsonb_build_array(jsonb_build_object('id', o.id, 'to', o.to_number, 'body', o.body)); end if;
    else
      v_status := 'sent';
    end if;
  else
    v_status := 'handoff';
    v_reason := coalesce(v_reason, case when v_a = '' then 'the FAQ does not answer it' else 'the model was not sure' end);
    if v_channel in ('email', 'whatsapp', 'messenger', 'instagram') then
      v_task := app.raise_task(p_type => 'auto_reply_handoff', p_title => left(format('Answer %s: %s', initcap(v_channel), coalesce(nullif(v_q, ''), 'a message')), 200),
        p_detail => left(format('From %s. The automatic answer was not used: %s. Reply in %s.', v_sender, v_reason,
                        case v_channel when 'email' then 'the inbox' when 'whatsapp' then 'WhatsApp' when 'messenger' then 'Facebook Page messages' else 'Instagram messages' end), 1000),
        p_queue => 'cs', p_dedupe => 'auto_reply:' || v_channel || ':' || md5(v_sender) || ':' || app.local_date(now()));
    end if;
    if v_channel = 'sms' and nullif(s.auto_reply_handoff_text, '') is not null then
      v_when := app.auto_reply_quiet_end(now());
      o := app.phone_outbox_put(v_sender, s.auto_reply_handoff_text, 'auto_reply', p_send_after => v_when, p_status => case when v_when <= now() then 'sending' else 'queued' end,
             p_dedupe => 'auto_reply_handoff:' || md5(v_sender) || ':' || app.local_date(now()));
      if o.status = 'sending' and o.created_at > now() - interval '1 minute' then v_send := jsonb_build_array(jsonb_build_object('id', o.id, 'to', o.to_number, 'body', o.body)); end if;
    end if;
  end if;
  insert into auto_replies (channel, sender, question, answer, status, reason, faq, neurons, model, outbox_id, task_id)
  values (v_channel, coalesce(nullif(v_sender, ''), '?'), nullif(v_q, ''), nullif(v_a, ''), v_status, v_reason,
          coalesce(array(select jsonb_array_elements_text(case when jsonb_typeof(p -> 'faq') = 'array' then p -> 'faq' else '[]'::jsonb end)), '{}'),
          v_neurons, nullif(p ->> 'model', ''), o.id, v_task)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'status', v_status, 'reason', v_reason, 'send', v_send,
    'handoff_text', case when v_status = 'handoff' and v_channel <> 'sms' then nullif(s.auto_reply_handoff_text, '') end);
end $$;

-- the website's live chat: its assistant answers only while auto_reply_chat is on too
create or replace function public.server_auto_reply_chat_on() returns boolean
language sql stable security definer set search_path = public, app as $$ select app.auto_reply_on('chat') $$;

-- Admin > Settings > Program shows the last answers (the card of the AI auto-replies group)
create or replace function app.auto_replies_recent(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs') or app.user_va_has(p_by, 'sales')) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return jsonb_build_object(
    'today', (select coalesce(jsonb_object_agg(status, n), '{}'::jsonb) from (select status, count(*) n from auto_replies where created_at >= app.local_midnight(app.local_date(now())) group by status) x),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'channel', a.channel, 'question', a.question, 'answer', a.answer, 'status', a.status, 'reason', a.reason, 'at', a.created_at) order by a.created_at desc)
                        from (select * from auto_replies order by created_at desc limit least(coalesce((p ->> 'limit')::integer, 30), 100)) a), '[]'::jsonb));
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2110;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_read', 'va_read', 'admin_read') and p_name = 'auto_replies' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.auto_replies_recent(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre2110(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2110(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'public' and p.proname = any (array['server_auto_reply_gate', 'server_auto_reply_record', 'server_auto_reply_chat_on']))
        or (n.nspname = 'app' and p.proname = any (array['auto_reply_quiet_end', 'auto_reply_on', 'auto_replies_recent', 'door_pre2110', 'ai_tier_pre2110', 'ai_feature_label_pre2110']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- the inboxes answered by email (the local parts of auto_reply_email_inboxes), only while email auto-replies are on
create or replace function public.server_auto_reply_inboxes() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when app.auto_reply_on('email') then coalesce(to_jsonb(array(select lower(btrim(x)) from unnest(string_to_array((app.settings()).auto_reply_email_inboxes, ',')) x where btrim(x) <> '')), '[]'::jsonb)
              else '[]'::jsonb end
$$;
revoke all on function public.server_auto_reply_inboxes() from public, anon, authenticated;
grant execute on function public.server_auto_reply_inboxes() to service_role;

-- the Meta webhook's side (Messenger, Instagram, WhatsApp): the verify token, which channels are on, and the Page token of
-- Meta publishing (0167) for the answers, for the server only. The Page token is given even while posting is off: answering
-- messages needs only the token.
create or replace function public.server_meta_messaging() returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  m meta_publishing;
  s program_settings := app.settings();
begin
  select * into m from meta_publishing limit 1;
  return jsonb_build_object('verify_token', s.auto_reply_meta_verify_token, 'graph_version', coalesce(m.graph_version, 'v21.0'),
    'page_id', m.page_id, 'ig_user_id', m.ig_user_id, 'whatsapp_phone_id', s.auto_reply_whatsapp_phone_id,
    'page_token', case when m.token_ref is not null and (app.auto_reply_on('messenger') or app.auto_reply_on('instagram')) then app.crm_secret_get(m.token_ref) end,
    'on', jsonb_build_object('messenger', app.auto_reply_on('messenger'), 'instagram', app.auto_reply_on('instagram'), 'whatsapp', app.auto_reply_on('whatsapp')));
end $$;
revoke all on function public.server_meta_messaging() from public, anon, authenticated;
grant execute on function public.server_meta_messaging() to service_role;
