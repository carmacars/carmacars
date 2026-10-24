-- 0133: the AI budget by feature, and the assistant adds rentals and offers (docs/changes/2026-10-24-ai-budget-and-assistant-tools.md)
--
-- The owner: "How r we running out of workers ai credits every single day like this? I haven't been able to use the staff
-- ai assistant once." and "Can rentals be added in by the ai chatbot?" Then: "Keep the usage limits as a hard stop: no
-- paid Workers AI overage. Reserve most of the free daily allowance for the staff assistant, visitor chat next, and the
-- SEO writer only from what is left late in the day or a small fixed share, never eating the staff share. Show staff a
-- clear message when the day's allowance is gone and when it resets."
--
-- Why it ran out: every Workers AI feature had its own daily ceiling (listing copy 9,000, live chat 6,000, search copy
-- 4,000, the assistant 3,000, vision 3,000, the phone line 1,500: 26,500 in all) on one shared pool of 10,000 free
-- neurons a day, first come, first served, each checked only as "used so far < ceiling" before a call that can cost
-- hundreds. The background jobs run all night: the search writer every five minutes (two items a tick, up to three
-- attempts each, 300 to 2,400 neurons an item) and the guide upkeep after every deploy (up to three attempts of 4,000
-- output tokens per changed section, about 600 neurons an attempt; 34 sections on the deploy of October 24 at 6 am).
-- The assistant could only run while the whole day was under 10,000, so by the time staff opened it the pool was gone.
--
-- 1. One budget for the day (app.ai_budget): the included Workers AI neurons (a hard stop: no paid usage, 2), split in
--    three tiers by the purpose each call is recorded with:
--      assistant   the staff assistant: may use everything nobody else used, and 70% of the day is kept for it alone
--                  (ai_assistant_reserve_bps).
--      live        someone is waiting: visitor live chat, the phone line, the toll reader, plate finder, guide
--                  suggestions. They share what is not reserved.
--      background  nobody is waiting: search copy, listing copy, guide rewrites, Turo email reading, the colour reader,
--                  and any use Cloudflare counts that the app did not record. A fixed 10% (ai_background_bps), and
--                  after 9 pm (ai_release_hour) what is left of the day, less a cushion kept for the assistant.
--    app.ai_allow(purpose, estimate): may this call run now, with the message to show when not. Each feature's own
--    gate asks it (live chat, the phone line, vision, the search job, the Turo matcher, the assistant's usage gate);
--    the Worker's adapters ask it before every call too (web/src/integrations/ai).
-- 2. Hard stop: paid usage cannot be allowed for Workers AI any more (app.usage_decide refuses it, and an allowance in
--    force today is withdrawn). Images and Claude keep their "Allow paid usage" question.
-- 3. Settings > Usage shows Workers AI by feature (today, the last 7 days, calls), the unmetered rest Cloudflare counts,
--    each tier's room now, and the shares (Admin-editable: ai_shares_save).
-- 4. The assistant adds rentals and offers: "create an offer" (app.staff_offer_create, 0129) and "add a rental"
--    (app.manual_rental_create, 0129) with the full summary on the card (assistant_actions.details: customer, car,
--    dates, price lines, deposit, payments) from the offer preview (rolled back); "what does X owe" reads the booking's
--    money (app.booking_money); a payment on a booking is recorded by part (app.record_booking_payment). A booking the
--    assistant made carries a booking event "Made with the staff assistant by <staff>".
-- No applied migration is edited: functions it changes are wrapped (renamed _pre0133).

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists ai_assistant_reserve_bps integer not null default 7000 check (ai_assistant_reserve_bps between 0 and 9500),
  add column if not exists ai_background_bps integer not null default 1000 check (ai_background_bps between 0 and 5000),
  add column if not exists ai_release_hour smallint default 21 check (ai_release_hour between 0 and 23),
  add column if not exists ai_assistant_cushion integer not null default 500 check (ai_assistant_cushion between 0 and 1000000);
comment on column program_settings.ai_assistant_reserve_bps is 'AI budget (0133): the share of the day''s free Workers AI neurons kept for the staff assistant alone (7000 = 70%). Nothing else may use it before the release hour.';
comment on column program_settings.ai_background_bps is 'AI budget (0133): the share of the day''s free Workers AI neurons background work may use before the release hour (search copy, listing copy, guide rewrites, Turo email reading; 1000 = 10%).';
comment on column program_settings.ai_release_hour is 'AI budget (0133): from this hour (Toronto) what is left of the day goes to the others, less ai_assistant_cushion. Empty: never.';
comment on column program_settings.ai_assistant_cushion is 'AI budget (0133): neurons always kept for the staff assistant after the release hour.';
-- the assistant's own ceiling no longer stops it below the day's allowance (it was 3,000 of the 10,000)
alter table program_settings alter column assistant_daily_neurons set default 10000;
update program_settings set assistant_daily_neurons = 10000 where assistant_daily_neurons < 10000;

-- the assistant's card: the summary and the details it was confirmed on
alter table assistant_actions add column if not exists details jsonb;
comment on column assistant_actions.details is 'The card''s details (0133): sections of label and value rows (customer, car, dates, price lines, deposit, payments) shown before Confirm.';

-- ================================================================ 2. tiers and the day's budget
create or replace function app.ai_tier(p_purpose text) returns text
language sql immutable as $$
  select case when p_purpose = 'staff_assistant' then 'assistant'
              when p_purpose in ('chat', 'phone_draft', 'phone_summary', 'toll_read', 'plate_detect', 'guide_review') then 'live'
              else 'background' end
$$;

create or replace function app.ai_feature_label(p_purpose text) returns text
language sql immutable as $$
  select case p_purpose
    when 'staff_assistant' then 'Staff assistant'
    when 'chat' then 'Visitor live chat'
    when 'phone_draft' then 'Phone line: reply drafts'
    when 'phone_summary' then 'Phone line: call summaries'
    when 'toll_read' then 'Toll and ticket reader'
    when 'plate_detect' then 'Plate finder on photos'
    when 'guide_review' then 'Guide suggestions'
    when 'seo_car' then 'Search copy: car pages'
    when 'seo_page' then 'Search copy: landing pages'
    when 'seo_article' then 'Search copy: articles'
    when 'draft_copy' then 'Listing copy of new cars'
    when 'guide_rewrite' then 'Guide upkeep after a deploy'
    when 'turo_email' then 'Turo email reading'
    when 'colour_read' then 'Car colour reader'
    else initcap(replace(coalesce(p_purpose, 'other'), '_', ' ')) end
$$;

-- The day's Workers AI budget now: what each tier used, the room each has, when it resets.
-- used = the larger of the app's own record (provider_calls) and the latest outside figure (Cloudflare); what Cloudflare
-- counts beyond the app's record is "unmetered" and counted as background, so it never eats the assistant's reserve.
create or replace function app.ai_budget(p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings(app.local_date(p_now));
  v_t0 timestamptz := app.local_midnight(app.local_date(p_now));
  v_inc numeric;
  v_a numeric; v_l numeric; v_b numeric; v_app numeric; v_ext numeric; v_all numeric; v_gap numeric;
  v_reserve numeric; v_bgcap numeric; v_cushion numeric; v_late boolean;
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
  v_cushion := least(ps.ai_assistant_cushion, v_reserve);
  v_late := ps.ai_release_hour is not null and app.local_hour(p_now) >= ps.ai_release_hour;
  r_a := least(v_inc - v_all, ps.assistant_daily_neurons - v_a);
  r_l := least(v_inc - v_all, case when v_late then v_inc - v_cushion - v_all else v_inc - v_reserve - (v_l + v_b) end);
  r_b := least(r_l, case when v_late then r_l else v_bgcap - v_b end);
  return jsonb_build_object(
    'included', v_inc, 'used', v_all, 'used_app', v_app, 'unmetered', v_gap, 'hard_stop', true,
    'tiers', jsonb_build_object('assistant', v_a, 'live', v_l, 'background', v_b),
    'room', jsonb_build_object('assistant', greatest(r_a, 0), 'live', greatest(r_l, 0), 'background', greatest(r_b, 0)),
    'reserve', v_reserve, 'background_cap', v_bgcap, 'cushion', v_cushion, 'late', v_late,
    'reserve_bps', ps.ai_assistant_reserve_bps, 'background_bps', ps.ai_background_bps, 'release_hour', ps.ai_release_hour,
    'assistant_daily', ps.assistant_daily_neurons,
    'resets_at', app.local_midnight(app.local_date(p_now) + 1));
end $$;

-- May a call of this purpose run now? p_est: about what it costs (a call is refused when it would not fit, so a
-- tier never runs past its room by more than one small call). Returns the budget with ok, tier, room and the message.
create or replace function app.ai_allow(p_purpose text, p_est numeric default 0, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b jsonb := app.ai_budget(p_now);
  v_tier text := app.ai_tier(p_purpose);
  v_room numeric := (b #>> array['room', v_tier])::numeric;
  v_ok boolean;
  v_msg text;
  v_used text := to_char((b ->> 'used')::numeric, 'FM999,999,990');
  v_inc text := to_char((b ->> 'included')::numeric, 'FM999,999,990');
begin
  v_ok :=v_room > 0 and (coalesce(p_est, 0) <= 0 or p_est <= v_room);
  if not v_ok then
    v_msg := case v_tier
      when 'assistant' then case when (b ->> 'used')::numeric >= (b ->> 'included')::numeric
          then format('Today''s free AI allowance is used up (%s of %s neurons). The assistant is back at midnight, Toronto time. Everything still works from the screens and pop-ups.', v_used, v_inc)
          when (b #>> '{tiers,assistant}')::numeric >= (b ->> 'assistant_daily')::numeric
          then format('The assistant reached its daily limit (%s neurons, Program settings). It is back at midnight, Toronto time. Everything still works from the screens and pop-ups.', to_char((b ->> 'assistant_daily')::numeric, 'FM999,999,990'))
          else format('Today''s free AI allowance is nearly used (%s of %s neurons): not enough is left for a question. The assistant is back at midnight, Toronto time. Everything still works from the screens and pop-ups.', v_used, v_inc) end
      when 'live' then 'The AI share for live chat, the phone line and the readers is used for today (the rest is kept for the staff assistant). It resets at midnight, Toronto time.'
      else format('Background AI writing waits: its share of today''s free allowance is used (the staff assistant keeps its reserve). It continues%s with what is left, or tomorrow.',
                  case when (b ->> 'release_hour') is not null and not (b ->> 'late')::boolean then format(' after %s:00', b ->> 'release_hour') else '' end) end;
  end if;
  return b || jsonb_build_object('ok', v_ok, 'purpose', p_purpose, 'tier', v_tier, 'tier_room', v_room, 'estimate', coalesce(p_est, 0), 'message', v_msg);
end $$;

-- Workers AI by feature, for Settings > Usage: today and the last 7 days (Toronto), with each tier's room now.
create or replace function app.ai_usage(p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_today date := app.local_date(p_now);
  v_t7 timestamptz := app.local_midnight(app.local_date(p_now) - 6);
  v_t0 timestamptz := app.local_midnight(app.local_date(p_now));
begin
  return app.ai_budget(p_now) || jsonb_build_object(
    'seo_writer', (app.settings()).seo_ai_writer_enabled,
    'features', coalesce((select jsonb_agg(jsonb_build_object('purpose', x.purpose, 'label', app.ai_feature_label(x.purpose), 'tier', app.ai_tier(x.purpose),
                          'today', x.today, 'calls_today', x.calls_today, 'failed_today', x.failed_today, 'week', x.week, 'calls_week', x.calls_week)
                          order by x.today desc, x.week desc)
        from (select c.purpose, coalesce(sum(c.units) filter (where c.created_at >= v_t0), 0) today, count(*) filter (where c.created_at >= v_t0) calls_today,
                     count(*) filter (where c.created_at >= v_t0 and not c.ok) failed_today, coalesce(sum(c.units), 0) week, count(*) calls_week
                from provider_calls c where c.unit = 'neurons' and c.created_at >= v_t7 and c.created_at < v_t0 + interval '1 day' group by c.purpose) x), '[]'::jsonb),
    'days', coalesce((select jsonb_agg(jsonb_build_object('day', d.day, 'assistant', d.a, 'live', d.l, 'background', d.b,
                         'cloudflare', (select max(r.used) from usage_readings r where r.service = 'workers_ai' and r.day = d.day and r.source <> 'app')) order by d.day)
        from (select app.local_date(c.created_at) as day,
                     coalesce(sum(c.units) filter (where app.ai_tier(c.purpose) = 'assistant'), 0) a,
                     coalesce(sum(c.units) filter (where app.ai_tier(c.purpose) = 'live'), 0) l,
                     coalesce(sum(c.units) filter (where app.ai_tier(c.purpose) = 'background'), 0) b
                from provider_calls c where c.unit = 'neurons' and c.created_at >= v_t7 group by 1) d where d.day <= v_today), '[]'::jsonb));
end $$;

-- An Admin changes the shares: p {reserve_bps, background_bps, release_hour (empty: never), cushion}. The row in force today.
create or replace function app.ai_shares_save(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid := (app.settings()).id;
  v_res integer := nullif(p ->> 'reserve_bps', '')::integer;
  v_bg integer := nullif(p ->> 'background_bps', '')::integer;
  v_cush integer := nullif(p ->> 'cushion', '')::integer;
begin
  perform app.assert_admin(p_user);
  if v_res is not null and (v_res < 0 or v_res > 9500) then raise exception 'The assistant''s reserve is between 0%% and 95%%' using errcode = '22023'; end if;
  if v_bg is not null and (v_bg < 0 or v_bg > 5000) then raise exception 'The background share is between 0%% and 50%%' using errcode = '22023'; end if;
  if coalesce(v_res, (app.settings()).ai_assistant_reserve_bps) + coalesce(v_bg, (app.settings()).ai_background_bps) > 10000 then
    raise exception 'The assistant''s reserve and the background share add up to more than 100%%' using errcode = '22023';
  end if;
  if p ? 'release_hour' and nullif(p ->> 'release_hour', '') is not null and (p ->> 'release_hour')::integer not between 0 and 23 then
    raise exception 'The release hour is from 0 to 23 (Toronto time), or empty for never' using errcode = '22023';
  end if;
  if v_cush is not null and (v_cush < 0 or v_cush > 1000000) then raise exception 'The cushion is 0 or more neurons' using errcode = '22023'; end if;
  update program_settings set ai_assistant_reserve_bps = coalesce(v_res, ai_assistant_reserve_bps), ai_background_bps = coalesce(v_bg, ai_background_bps),
         ai_release_hour = case when p ? 'release_hour' then nullif(p ->> 'release_hour', '')::smallint else ai_release_hour end,
         ai_assistant_cushion = coalesce(v_cush, ai_assistant_cushion)
   where id = v_id;
  return app.ai_budget();
end $$;

-- ================================================================ 3. every gate asks the budget
-- the staff assistant (0080's usage gate): ok while the assistant tier has room
alter function app.usage_gate(text, timestamptz) rename to usage_gate_pre0133;
create function app.usage_gate(p_service text, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  st jsonb := app.usage_gate_pre0133(p_service, p_now);
  a jsonb;
begin
  if p_service <> 'workers_ai' then return st; end if;
  a := app.ai_allow('staff_assistant', 0, p_now);
  return st || jsonb_build_object('ok', (a ->> 'ok')::boolean, 'assistant_used', a #> '{tiers,assistant}', 'assistant_room', a #> '{room,assistant}',
    'used', a -> 'used', 'included', a -> 'included', 'resets_at', a -> 'resets_at', 'message', a -> 'message', 'budget', a);
end $$;

-- live chat (0060)
alter function app.chat_budget() rename to chat_budget_pre0133;
create function app.chat_budget() returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b jsonb := app.chat_budget_pre0133();
  a jsonb := app.ai_allow('chat', 150);
begin
  return b || jsonb_build_object('ok', coalesce((b ->> 'ok')::boolean, false) and (a ->> 'ok')::boolean, 'tier_room', a -> 'tier_room', 'tier_message', a -> 'message');
end $$;

-- the phone line (0085)
alter function app.phone_ai_budget() rename to phone_ai_budget_pre0133;
create function app.phone_ai_budget() returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b jsonb := app.phone_ai_budget_pre0133();
  a jsonb := app.ai_allow('phone_draft', 150);
begin
  return b || jsonb_build_object('ok', coalesce((b ->> 'ok')::boolean, false) and (a ->> 'ok')::boolean, 'tier_room', a -> 'tier_room');
end $$;

-- the vision readers (0042, 0049)
alter function app.ai_vision_gate(uuid, text) rename to ai_vision_gate_pre0133;
create function app.ai_vision_gate(p_by uuid, p_purpose text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  g jsonb := app.ai_vision_gate_pre0133(p_by, p_purpose);
  a jsonb;
begin
  if not coalesce((g ->> 'allowed')::boolean, false) then return g; end if;
  a := app.ai_allow(p_purpose, 300);
  if not (a ->> 'ok')::boolean then return g || jsonb_build_object('allowed', false, 'reason', a ->> 'message'); end if;
  return g;
end $$;

-- the Turo email matcher (0063, 0088): the model helps only within the background share
alter function app.turo_match_keys() rename to turo_match_keys_pre0133;
create function app.turo_match_keys() returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  k jsonb := app.turo_match_keys_pre0133();
begin
  return k || jsonb_build_object('ai_ok', coalesce((k ->> 'ai_ok')::boolean, false) and (app.ai_allow('turo_email', 100) ->> 'ok')::boolean);
end $$;

-- the search job (0061, 0087, 0104): nothing is claimed for writing while the background share has no room for an item
-- (about 800 neurons: a car page's first attempt); IndexNow and the landing page figures go on as before
alter function app.server_seo_claim(text, integer) rename to server_seo_claim_pre0133;
create function app.server_seo_claim(p_worker text, p_limit integer default 3) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a jsonb := app.ai_allow('seo_car', 800);
begin
  if not (a ->> 'ok')::boolean then
    return app.server_seo_claim_pre0133(p_worker, 0) || jsonb_build_object('ai_wait', a ->> 'message');
  end if;
  return app.server_seo_claim_pre0133(p_worker, p_limit);
end $$;

-- ================================================================ 4. hard stop: no paid Workers AI
alter function app.usage_decide(uuid, jsonb, timestamptz) rename to usage_decide_pre0133;
create function app.usage_decide(p_user uuid, p jsonb, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p ->> 'service' = 'workers_ai' and coalesce(p ->> 'decision', '') = 'allow' then
    perform app.assert_admin(p_user);
    raise exception 'Workers AI stops at the free daily allowance: paid usage is not offered. The staff assistant keeps its share (Settings > Usage, Workers AI by feature).' using errcode = '22023';
  end if;
  return app.usage_decide_pre0133(p_user, p, p_now);
end $$;

-- an allowance in force today stops; its record stays in the history with a note
update usage_decisions set note = left(coalesce(note || ' ', '') || 'Withdrawn by 0133: Workers AI stops at the free allowance.', 300)
 where service = 'workers_ai' and decision = 'allow' and ends_on >= app.today();
delete from usage_decisions where service = 'workers_ai' and decision = 'allow' and starts_on > app.today();
alter function app.usage_apply(text, timestamptz) rename to usage_apply_pre0133;
create function app.usage_apply(p_service text, p_now timestamptz default now()) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.usage_apply_pre0133(p_service, p_now);
  if p_service = 'workers_ai' then update usage_services set paid_extra = 0 where service = 'workers_ai'; end if;
end $$;
-- the state of a day with an old allowance: paused, not "paid"
alter function app.usage_state(text, timestamptz) rename to usage_state_pre0133;
create function app.usage_state(p_service text, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  st jsonb := app.usage_state_pre0133(p_service, p_now);
begin
  if p_service = 'workers_ai' then
    st := st || jsonb_build_object('decision', null, 'hard_stop', true);
    if st ->> 'state' = 'paid' then st := st || jsonb_build_object('state', 'paused', 'paused', true); end if;
  end if;
  return st;
end $$;
update usage_services set paid_extra = 0,
  label = 'Workers AI (assistant, live chat, copy, email reading)',
  price_text = 'Free allowance only: Workers AI stops at the included neurons each day and never runs into paid usage.',
  when_used_up = 'Stopped until midnight, never paid. The staff assistant keeps its reserved share all day; live chat goes to a person, listing and search copy wait (the template text stays), Turo emails are read by the rules only.',
  measured_by = 'Every AI call the app makes is recorded with its feature and neurons (provider_calls); Cloudflare''s own count is used too when the usage workflow reports it (the larger counts, the difference shown as unmetered).'
 where service = 'workers_ai';

-- ================================================================ 5. Settings > Usage: Workers AI by feature
alter function app.usage_page(uuid, timestamptz) rename to usage_page_pre0133;
create function app.usage_page(p_user uuid, p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  return app.usage_page_pre0133(p_user, p_now) || jsonb_build_object('ai', app.ai_usage(p_now));
end $$;

-- ================================================================ 6. the assistant: offers, rentals, balances
alter function app.assistant_action_door(text, text, text) rename to assistant_action_door_pre0133;
create function app.assistant_action_door(p_tool text, p_portal text, p_name text) returns text
language sql immutable as $$
  select case
    when p_tool = 'create_offer' and p_name = 'offer_create' and p_portal in ('admin', 'va') then 'ops_do'
    when p_tool = 'record_payment' and p_name = 'record_booking_payment' then 'ops_do'
    else app.assistant_action_door_pre0133(p_tool, p_portal, p_name) end
$$;

-- the card keeps its details (p.details: [{title, rows: [{label, value}]}])
alter function app.assistant_propose(uuid, jsonb) rename to assistant_propose_pre0133;
create function app.assistant_propose(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb := app.assistant_propose_pre0133(p_user, p);
  v_details jsonb := case when jsonb_typeof(p -> 'details') = 'array' then p -> 'details' end;
begin
  if v_details is not null then
    if length(v_details::text) > 8000 then raise exception 'The card''s details are too long' using errcode = '22023'; end if;
    update assistant_actions set details = v_details where id = (r ->> 'id')::uuid;
  end if;
  return r || jsonb_build_object('details', coalesce(v_details, '[]'::jsonb));
end $$;

-- a booking the assistant made or paid says so in its history, with the staff member's name
alter function app.assistant_confirm(uuid, text, jsonb) rename to assistant_confirm_pre0133;
create function app.assistant_confirm(p_user uuid, p_aal text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb := app.assistant_confirm_pre0133(p_user, p_aal, p);
  a assistant_actions;
  b bookings;
begin
  if not coalesce((r ->> 'ok')::boolean, false) then return r; end if;
  select * into a from assistant_actions where id = (r ->> 'id')::uuid;
  if a.name in ('offer_create', 'manual_rental_create', 'record_booking_payment') then
    select * into b from bookings where id::text = coalesce(r #>> '{result,booking_id}', '') or booking_number = coalesce(r #>> '{result,booking_number}', a.args ->> 'booking', '')
      or id::text = coalesce(a.args ->> 'booking', '') limit 1;
    if b.id is not null then
      perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version,
        format('%s with the staff assistant by %s: %s', case a.name when 'offer_create' then 'Offer made' when 'manual_rental_create' then 'Rental added' else 'Payment recorded' end,
               coalesce((select u.full_name from users u where u.id = p_user), 'staff'), left(a.summary, 300)),
        p_user, 'staff', jsonb_build_object('assistant_action_id', a.id, 'via', 'assistant'));
    end if;
  end if;
  return r;
end $$;

-- ================================================================ 7. the doors
create or replace function app.ops133(p_user uuid, p_aal text, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  case p_name
  when 'ai_shares_save' then return app.ai_shares_save(p_user, p);
  else raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0133;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_do' and p_name = 'ai_shares_save' then
    perform app.door_begin(p_user, p_aal);
    return app.ops133(p_user, p_aal, p_call, p_name, coalesce(p, '{}'::jsonb));
  end if;
  return app.door_pre0133(p_user, p_aal, p_call, p_name, p);
end $$;

-- the Worker's adapters (service role): the budget before each call
create or replace function public.server_ai_budget() returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.ai_budget() $$;
create or replace function public.server_ai_allow(p_purpose text, p_est numeric default 0) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.ai_allow(p_purpose, p_est) $$;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['ai_budget', 'ai_allow', 'ai_usage', 'ai_shares_save', 'usage_gate', 'usage_gate_pre0133', 'chat_budget', 'chat_budget_pre0133',
              'phone_ai_budget', 'phone_ai_budget_pre0133', 'ai_vision_gate', 'ai_vision_gate_pre0133', 'turo_match_keys', 'turo_match_keys_pre0133', 'server_seo_claim',
              'server_seo_claim_pre0133', 'usage_decide', 'usage_decide_pre0133', 'usage_apply', 'usage_apply_pre0133', 'usage_state', 'usage_state_pre0133',
              'usage_page', 'usage_page_pre0133', 'assistant_action_door', 'assistant_action_door_pre0133', 'assistant_propose', 'assistant_propose_pre0133',
              'assistant_confirm', 'assistant_confirm_pre0133', 'ops133', 'door', 'door_pre0133']))
        or (n.nspname = 'public' and p.proname = any (array['server_ai_budget', 'server_ai_allow']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
-- the tier and label are plain words, safe for anyone
grant execute on function app.ai_tier(text) to authenticated, service_role;
grant execute on function app.ai_feature_label(text) to authenticated, service_role;

-- ================================================================ 8. search copy: written by the daily Claude batch, not Workers AI
-- The owner, October 24: the search text is written by a daily scheduled Claude session instead of Workers AI, leaving
-- the whole free Workers AI allowance to the staff assistant and live chat. The website's writer is off by default
-- (seo_ai_writer_enabled; an Admin may turn it on again, then it writes within the background share of section 2).
-- The batch: .github/workflows/seo-queue.yml reads app.seo_batch_queue (the pages that need text, most valuable first,
-- with the facts the writer needs) into seo/queue/latest.json on the branch seo-queue; the session commits
-- seo/batches/*.json to main; .github/workflows/seo-import.yml checks every item with the website's own checks
-- (web/src/features/seo/batch.ts) and publishes the ones that pass through app.seo_batch_publish (source
-- 'claude-batch'), which queues them for IndexNow (docs/seo-batches.md). Hand-written text (claude-batch) comes before
-- the writing kit's text, which comes before the old template: the queue never offers a page whose current text is
-- claude-batch or Workers AI and still matches its facts.
alter table program_settings add column if not exists seo_ai_writer_enabled boolean not null default false;
comment on column program_settings.seo_ai_writer_enabled is 'Search copy (0133): the website writes car, landing page and article text with Workers AI. Off: the daily Claude batch writes it (docs/seo-batches.md).';

alter table car_copy drop constraint if exists car_copy_source_check;
alter table car_copy add constraint car_copy_source_check check (source in ('template', 'ai', 'claude-batch', 'kit'));
alter table seo_pages drop constraint if exists seo_pages_source_check;
alter table seo_pages add constraint seo_pages_source_check check (source in ('seed', 'ai', 'staff', 'claude-batch', 'kit'));
alter table articles drop constraint if exists articles_source_check;
alter table articles add constraint articles_source_check check (source in ('seed', 'ai', 'staff', 'claude-batch', 'kit'));

-- the website's writer off: nothing is claimed for writing (IndexNow goes on)
alter function app.server_seo_claim(text, integer) rename to server_seo_claim_ai0133;
create function app.server_seo_claim(p_worker text, p_limit integer default 3) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if not (app.settings()).seo_ai_writer_enabled then
    return app.server_seo_claim_pre0133(p_worker, 0) || jsonb_build_object('ai_wait', 'The search copy is written by the daily Claude batch (docs/seo-batches.md); the website''s Workers AI writer is off in Program settings.');
  end if;
  return app.server_seo_claim_ai0133(p_worker, p_limit);
end $$;

-- The pages that need text, most valuable first: landing pages (places first, then uses), then the car pages of
-- published cars (asked for first), then the guides. "Needs text": never written by a person or a model, written
-- before the facts changed, or waiting (pending or failed). Each with what the writer needs.
create or replace function app.seo_batch_queue(p_limit integer default 500) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  v_city text := (select city from site_settings limit 1);
  v_items jsonb;
begin
  perform 1;
  with pages as (
    select 1 as tier, row_number() over (order by (p.kind = 'location') desc, coalesce(p.was_indexable, true) desc, p.status in ('pending', 'failed') desc, p.slug) as n,
           jsonb_build_object('kind', 'page', 'id', p.slug, 'url', '/car-rental/' || p.slug, 'page_type', p.kind, 'name', p.name, 'city', v_city,
             'facts', p.facts, 'locked', to_jsonb(p.locked), 'current', p.copy, 'source', p.source, 'status', p.status,
             'others', coalesce((select jsonb_agg(o.copy ->> 'intro') from seo_pages o where o.slug <> p.slug and o.source in ('ai', 'claude-batch') and o.copy ? 'intro'), '[]'::jsonb)) as item
      from seo_pages p
     where p.is_active and (p.source not in ('ai', 'claude-batch', 'staff') or p.status in ('pending', 'failed') or p.copy_facts_hash is distinct from p.facts_hash)),
  cars as (
    select 2 as tier, row_number() over (order by (l.status = 'published') desc, cc.asked_at desc nulls last, (cc.source in ('template', 'kit')) desc, cc.vehicle_id) as n,
           jsonb_build_object('kind', 'car', 'id', cc.vehicle_id, 'url', case when l.slug is not null then '/cars/' || l.slug end, 'page_type', 'car',
             'name', app.vehicle_name(cc.vehicle_id), 'facts', cc.facts, 'locked', to_jsonb(cc.locked), 'current', cc.copy, 'source', cc.source, 'status', cc.status,
             'others', (select coalesce(jsonb_agg(o.copy ->> 'intro'), '[]'::jsonb) from car_copy o join vehicles ov on ov.id = o.vehicle_id, vehicles v
                         where v.id = cc.vehicle_id and o.vehicle_id <> cc.vehicle_id and o.source in ('ai', 'claude-batch')
                           and app.slugify(ov.make || ' ' || ov.model) = app.slugify(v.make || ' ' || v.model))) as item
      from car_copy cc left join vehicle_listings l on l.vehicle_id = cc.vehicle_id
     where app.car_copy_eligible(cc.vehicle_id)
       and (cc.source in ('template', 'kit') or cc.status in ('pending', 'failed') or cc.copy_facts_hash is distinct from cc.facts_hash)),
  arts as (
    select 3 as tier, row_number() over (order by a.status in ('pending', 'failed') desc, a.slug) as n,
           jsonb_build_object('kind', 'article', 'id', a.slug, 'url', '/guides/' || a.slug, 'page_type', 'article', 'name', a.title,
             'brief', a.brief, 'locked', to_jsonb(a.locked), 'current', jsonb_build_object('title', a.title, 'description', a.description, 'body_md', a.body_md, 'faq', a.faq),
             'source', a.source, 'status', a.status) as item
      from articles a
     where a.source not in ('ai', 'claude-batch', 'staff') or a.status in ('pending', 'failed'))
  select coalesce(jsonb_agg(x.item || jsonb_build_object('priority', x.rank) order by x.rank), '[]'::jsonb) into v_items
    from (select item, row_number() over (order by tier, n) as rank from (select * from pages union all select * from cars union all select * from arts) u) x
   where x.rank <= greatest(least(coalesce(p_limit, 500), 5000), 1);
  return jsonb_build_object('generated_at', now(), 'city', v_city, 'banned', to_jsonb(ps.listing_banned_phrases),
    'similarity_max_bps', ps.seo_copy_similarity_max_bps, 'items', v_items,
    'waiting', jsonb_build_object('pages', (select count(*) from seo_pages p where p.is_active and (p.source not in ('ai', 'claude-batch', 'staff') or p.status in ('pending', 'failed') or p.copy_facts_hash is distinct from p.facts_hash)),
                                  'cars', (select count(*) from car_copy cc where app.car_copy_eligible(cc.vehicle_id) and (cc.source in ('template', 'kit') or cc.status in ('pending', 'failed') or cc.copy_facts_hash is distinct from cc.facts_hash)),
                                  'articles', (select count(*) from articles a where a.source not in ('ai', 'claude-batch', 'staff') or a.status in ('pending', 'failed'))));
end $$;

-- The facts as they are now for the items of a batch (by id or by address), so the import checks against the live facts.
-- p: [{kind?, id?, url?}]. Each: the queue item's shape, or {ref, missing: true}.
create or replace function app.seo_batch_context(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  v_city text := (select city from site_settings limit 1);
  r jsonb;
  v_kind text;
  v_id text;
  v_out jsonb := '[]'::jsonb;
  v_item jsonb;
begin
  for r in select * from jsonb_array_elements(coalesce(p, '[]'::jsonb)) loop
    v_kind := r ->> 'kind'; v_id := r ->> 'id';
    if v_id is null and r ->> 'url' like '/car-rental/%' then v_kind := 'page'; v_id := substr(r ->> 'url', 13); end if;
    if v_id is null and r ->> 'url' like '/guides/%' then v_kind := 'article'; v_id := substr(r ->> 'url', 9); end if;
    if v_id is null and r ->> 'url' like '/cars/%' then v_kind := 'car'; v_id := (select l.vehicle_id::text from vehicle_listings l where l.slug = substr(r ->> 'url', 7) limit 1); end if;
    v_item := null;
    if v_kind = 'page' then
      select jsonb_build_object('kind', 'page', 'id', p2.slug, 'url', '/car-rental/' || p2.slug, 'page_type', p2.kind, 'name', p2.name, 'city', v_city, 'facts', p2.facts,
               'locked', to_jsonb(p2.locked), 'current', p2.copy, 'source', p2.source,
               'others', coalesce((select jsonb_agg(o.copy ->> 'intro') from seo_pages o where o.slug <> p2.slug and o.source in ('ai', 'claude-batch') and o.copy ? 'intro'), '[]'::jsonb))
        into v_item from seo_pages p2 where p2.slug = v_id and p2.is_active;
    elsif v_kind = 'car' and v_id ~ '^[0-9a-f-]{36}$' then
      select jsonb_build_object('kind', 'car', 'id', cc.vehicle_id, 'url', (select '/cars/' || l.slug from vehicle_listings l where l.vehicle_id = cc.vehicle_id and l.slug is not null),
               'page_type', 'car', 'name', app.vehicle_name(cc.vehicle_id), 'facts', cc.facts, 'locked', to_jsonb(cc.locked), 'current', cc.copy, 'source', cc.source,
               'others', (select coalesce(jsonb_agg(o.copy ->> 'intro'), '[]'::jsonb) from car_copy o join vehicles ov on ov.id = o.vehicle_id, vehicles v
                           where v.id = cc.vehicle_id and o.vehicle_id <> cc.vehicle_id and o.source in ('ai', 'claude-batch')
                             and app.slugify(ov.make || ' ' || ov.model) = app.slugify(v.make || ' ' || v.model)),
               'all_intros', (select coalesce(jsonb_agg(o.copy ->> 'intro'), '[]'::jsonb) from car_copy o where o.vehicle_id <> cc.vehicle_id and o.source in ('ai', 'claude-batch')))
        into v_item from car_copy cc where cc.vehicle_id = v_id::uuid and app.car_copy_eligible(cc.vehicle_id);
    elsif v_kind = 'article' then
      select jsonb_build_object('kind', 'article', 'id', a.slug, 'url', '/guides/' || a.slug, 'page_type', 'article', 'name', a.title, 'brief', a.brief, 'locked', to_jsonb(a.locked),
               'current', jsonb_build_object('title', a.title, 'description', a.description, 'body_md', a.body_md, 'faq', a.faq), 'source', a.source,
               'others', coalesce((select jsonb_agg(o.body_md) from articles o where o.slug <> a.slug), '[]'::jsonb))
        into v_item from articles a where a.slug = v_id;
    end if;
    v_out := v_out || jsonb_build_array(coalesce(v_item, jsonb_build_object('ref', r, 'missing', true)));
  end loop;
  return jsonb_build_object('items', v_out, 'banned', to_jsonb(ps.listing_banned_phrases), 'similarity_max_bps', ps.seo_copy_similarity_max_bps, 'city', v_city);
end $$;

-- Publishes the items that passed the checks (web/src/features/seo/batch.ts), as the search job publishes its own
-- (app.server_seo_result): a car through app.car_copy_apply (the database's own checks run again; the listing follows;
-- IndexNow is queued), a landing page or an article with its locked fields kept (their IndexNow triggers queue them).
-- Source 'claude-batch'. p: {items: [{kind, id, copy | title, description, body_md, faq, prompt_version}]}.
create or replace function app.seo_batch_publish(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb;
  v_kind text;
  v_id text;
  v_out jsonb := '[]'::jsonb;
  pg seo_pages;
  a articles;
  k text;
  v_new jsonb;
begin
  for r in select * from jsonb_array_elements(coalesce(p -> 'items', '[]'::jsonb)) loop
    v_kind := r ->> 'kind'; v_id := r ->> 'id';
    begin
      if v_kind = 'car' then
        perform app.car_copy_apply(v_id::uuid, r -> 'copy', 'claude-batch', (select facts_hash from car_copy where vehicle_id = v_id::uuid));
        update car_copy set model = 'claude-batch', prompt_version = coalesce(r ->> 'prompt_version', prompt_version), runs = runs + 1, generated_at = now() where vehicle_id = v_id::uuid;
        v_out := v_out || jsonb_build_array(jsonb_build_object('kind', 'car', 'id', v_id, 'status', 'published',
                  'url', (select '/cars/' || l.slug from vehicle_listings l where l.vehicle_id = v_id::uuid and l.slug is not null)));
      elsif v_kind = 'page' then
        select * into pg from seo_pages where slug = v_id for update;
        if pg.slug is null then raise exception 'Landing page not found' using errcode = 'P0002'; end if;
        v_new := r -> 'copy';
        if jsonb_typeof(v_new) <> 'object' then raise exception 'The page''s copy is missing' using errcode = '22023'; end if;
        foreach k in array pg.locked loop if pg.copy ? k then v_new := v_new || jsonb_build_object(k, pg.copy -> k); end if; end loop;
        update seo_pages set copy = v_new, source = 'claude-batch', status = 'published', copy_facts_hash = facts_hash, attempts = 0, problems = '{}', last_error = null,
               locked_at = null, model = 'claude-batch', prompt_version = coalesce(r ->> 'prompt_version', prompt_version), generated_at = now()
         where slug = v_id;
        v_out := v_out || jsonb_build_array(jsonb_build_object('kind', 'page', 'id', v_id, 'status', 'published', 'url', '/car-rental/' || v_id));
      elsif v_kind = 'article' then
        select * into a from articles where slug = v_id for update;
        if a.slug is null then raise exception 'Article not found' using errcode = 'P0002'; end if;
        if nullif(btrim(r ->> 'body_md'), '') is null then raise exception 'The article''s body is missing' using errcode = '22023'; end if;
        update articles set
          title = case when 'title' = any (locked) then title else coalesce(nullif(btrim(r ->> 'title'), ''), title) end,
          description = case when 'description' = any (locked) then description else coalesce(nullif(btrim(r ->> 'description'), ''), description) end,
          body_md = case when 'body_md' = any (locked) then body_md else r ->> 'body_md' end,
          faq = case when 'faq' = any (locked) or coalesce(jsonb_typeof(r -> 'faq'), '') <> 'array' then faq else r -> 'faq' end,
          source = 'claude-batch', status = 'published', attempts = 0, problems = '{}', last_error = null, locked_at = null,
          model = 'claude-batch', prompt_version = coalesce(r ->> 'prompt_version', prompt_version), generated_at = now()
         where slug = v_id;
        v_out := v_out || jsonb_build_array(jsonb_build_object('kind', 'article', 'id', v_id, 'status', 'published', 'url', '/guides/' || v_id));
      else
        raise exception 'Unknown kind %', coalesce(v_kind, '(none)') using errcode = '22023';
      end if;
    exception when others then
      v_out := v_out || jsonb_build_array(jsonb_build_object('kind', v_kind, 'id', v_id, 'status', 'rejected', 'problems', jsonb_build_array(regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''))));
    end;
  end loop;
  insert into audit_log (action, entity_table, entity_id, after)
  values ('seo_batch_publish', 'seo_pages', 'claude-batch', jsonb_build_object('published', (select count(*) from jsonb_array_elements(v_out) e where e ->> 'status' = 'published'),
          'rejected', (select count(*) from jsonb_array_elements(v_out) e where e ->> 'status' = 'rejected'), 'batch', p ->> 'batch'));
  return jsonb_build_object('results', v_out);
end $$;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['server_seo_claim', 'server_seo_claim_ai0133', 'seo_batch_queue', 'seo_batch_context', 'seo_batch_publish'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ the guides
-- GUIDES 0133 START (generated by supabase/seed/0133_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('admin', 'search-car-pages-landing-pages-and-guides', 'chapter', 'discount-games-and-leads', 'The text of every car page, the landing pages for each area and way of renting, and the guides are written by Workers AI from the facts in the database, checked and published by themselves. Nobody has to type or review anything. You can still change any line; what you change is kept.

## The copy of a car

**Cars** > **Vehicles**, then the car, then its Listing tab. The same card is on the listing review.

1. The card says who wrote the text: a plain copy from the car''s facts while the written copy is prepared (usually minutes), then Workers AI.
2. Every field is shown: search title and description, heading, introduction, highlights, good for, what''s included, pickup and delivery, requirements, questions and the photo descriptions.
3. To change a field press **Change**, then **Save and lock**. A locked field is kept by every new version. **Unlock** lets it be written again.
4. **Write again** asks for a new version now. A new version is also written by itself when the car''s facts change: its rates, specs, area or photos.

> Good to know: The checks refuse long dashes, sales words, the numbered company, any number that is not in the car''s facts (a price, a seat count) and equipment the facts do not list. A version that fails is asked again with the problems named; if it still fails, the page keeps its current text and it is tried again later.

## Landing pages and guides

**Settings** > **All settings**, then Search.

1. Today: the Workers AI used for search copy and in all, and IndexNow (addresses waiting and sent).
2. Car copy: every real car, who wrote its text, and whether its facts changed since.
3. Landing pages: each place and way of renting, whether it is in search, its cars and who wrote it. A page for a way of renting (monthly, SUV) goes into search once enough real cars match it (Program settings).
4. Open **Edit** on a page or a guide to change its text. Edited fields are locked. **Write again** asks for a new version; on a guide, the brief says what it must cover.

## Vehicle pages

**Settings** > **Vehicle pages**. A page for every make, model, model year and Canadian trim of every year, at carmacars.ca/cars/make/model/year/trim, with our cars below it; each trim also in every place and in 12 colours (a black 2020 Volkswagen Jetta Sportline in Mississauga, for example); every page again for sale (carmacars.ca/buy/...) and for each search term: renting (car hire), sale (financing), detailing (ceramic coating) and body shop (bumper repair), at carmacars.ca/t/term/...

1. Pages: how many pages each level and each tier has, the total, and how many are in search. Every page is in search by default; nothing needs setting up.
2. One switch per tier takes it out of search at once: **Index the place pages**, **Index the colour pages**, **Index the search term pages**, **Index the /buy pages**, **Index the detailing pages**, **Index the body shop pages**. Off, those pages stay visible but leave the sitemaps and search.
3. The places are the place list of the local search release (every city, town and neighbourhood, with GTA and country levels); until it is filled, the area landing pages. The search terms are edited with them.
4. **Financing disclaimer**: the text on financing and leasing pages. CarmaCars never says it lends or leases.
5. Database: its size against the cap the catalog and places imports keep under: the cap of the Database plan (Pro, 6,144 MB, by default; Free, 450 MB). IndexNow: the addresses sent today, where the sweep is, and any back-off; nothing to do.
6. Each page is built from data: the EPA fuel-use ratings in litres per 100 km, the cost to drive 100 km at the gas or electricity price set here, what changed from the year before, how a trim differs from the others, similar models, and the rental questions from the program settings.
7. Below the facts: our cars of that exact year, model and trim, then the same model in other years, then similar cars free now, and Request it, which sends an enquiry to Bookings > Leads.
8. Settings: **Index every page** (the default) or **Only pages that pass the rules**: makes, models with 2 or more years of data, years with one of our cars or of a popular model from 2015, trims with one of our cars. The others stay visible but out of search. Also the gas, premium and electricity prices, and how often the catalog is imported (every 30 days).
9. Canadian trims: open a model and type one line per run of years, entry trim first: 2020-2021: Comfortline, Highline, Sportline, Execline. Your lines are kept by every import; empty them to go back to the CarmaCars list. **Add trims for another model** adds a model that has none.
10. Catalog import: the last import and its counts. **Import now** asks for a new one; it runs at the next daily check, at 07:17 UTC.

> Good to know: A car joins its pages by itself once it is on the site: its make, model, year and trim are read from the car. A trim that names several (S / SE / R-Line) leaves the car on the year page only; set the car''s trim to one Canadian name to put it on the trim page.

## A car for sale

**Cars** > **Vehicles**, then the car. On the For sale card, tick **For sale**, enter the Asking price and press **Save**.

1. The car then shows at the top of its /buy pages (its make, model, year and trim) with the asking price, the only time a page says a car is for sale.
2. Untick it when the car is sold or no longer for sale: the pages say so at once.
3. "Find me this car" on the /buy pages sends a buyer lead to Sales (staff portal: **Owner leads**, Buyer leads), with a To do line.

## Search engines and business listings

**Settings** > **All settings**, then Site settings.

1. Search engines: paste the Google Search Console value (HTML tag) or the file name (HTML file), and the Bing value. The steps are on the card.
2. Business name, address and phone: the exact text for every listing, and the description and categories.
3. Business listings: press **Copy** beside each line and paste it into Google Business Profile, Bing Places, Apple Business Connect, Yelp, Yellow Pages and Facebook. Tick each one when it is done.

> Good to know: Changed pages are sent to IndexNow (Bing and the other engines that use it) by themselves. Google reads the sitemap: submit carmacars.ca/sitemap.xml once in Search Console.

## Place pages

Every place we have, from a country down to a neighbourhood, gets a page for every term people search with: renting (car hire, SUV rental, monthly car rental ...), buying help (used cars, car financing ...), detailing (ceramic coating, window tint ...) and body work (collision repair, dent repair ...). Each page is written from real data only: the distance from us, the delivery price within our reach, the nearest airport, the landmarks near it, our live cars and the places around it. A place far from Toronto says we serve the Toronto area and takes a request instead. **Settings** > **All settings**, then Search.

1. Place pages: four switches, one for each family, put the pages in search and in the sitemaps. All four are on.
2. Quality gate: off. On, only places within the delivery reach are in search, and rental pages only with a real matching car. Search engines can treat many similar pages as low value; the gate lowers that risk.
3. Delivery reach: places within this distance of our location are offered delivery. Database size cap: the places import stops before the database passes it.
4. Regions and places: every province, state and territory is on. Untick a region to take its pages and sitemaps off the site.
5. Terms and services: change a term''s title or what is true about it, point a synonym to another term (its pages then leave search), switch a term off, or add one. Give a service a starting price, or leave it empty for "price on request".

> Good to know: A region has pages once the places workflow has loaded it: GitHub, Actions, places, Run workflow, with the regions or all. The run loads Ontario first and names any region it skipped because of the size cap.

## Requests from the place pages

The buying help, detailing and body shop pages, and the pages of places beyond our reach, have a request form. Each request is a lead with a task in **To do**: detailing and body shop requests are due within an hour of opening and show in Today. Buying help pages say plainly that CarmaCars does not sell, finance or lease cars; the notice at the top is set under Place pages.

Mechanical work has pages too, under the body shop pages and listed apart as "Auto services we arrange": a mechanic, oil changes, brakes, tires and winter tires, towing, batteries and boosts, alignment, transmission and engine repair, diagnostics, inspections and the Ontario safety certificate, emissions, AC, exhaust and suspension. CarmaCars does not do this work, and the pages say so: each takes a request (a "Mechanical work to arrange" task, due within an hour of opening) and offers a rental while the car is in. They have no questions of their own; their per car pages (for each make, model, year and trim) say the same and take the same request.

## One name, address and phone

The footer, the contact page, the structured data and every business listing show the business address of Site settings. Keep it the address renters come to, and change it there only.
', 'Search: car pages, landing pages and guides', 'Car copy written by itself, landing pages, place pages for every place and term, detailing and body shop, guides, business listings and IndexNow.',
  'The text of every car page, the landing pages for each area and way of renting, and the guides are written every day by a scheduled Claude session from the facts in the database, checked with the site''s own checks and published by themselves (the website''s Workers AI writer is off, so the free AI allowance stays with the staff assistant). Nobody has to type or review anything. You can still change any line; what you change is kept.

## The copy of a car

**Cars** > **Vehicles**, then the car, then its Listing tab. The same card is on the listing review.

1. The card says who wrote the text: a plain copy from the car''s facts while the written copy is prepared (the next daily batch), then the batch (claude-batch) or Workers AI.
2. Every field is shown: search title and description, heading, introduction, highlights, good for, what''s included, pickup and delivery, requirements, questions and the photo descriptions.
3. To change a field press **Change**, then **Save and lock**. A locked field is kept by every new version. **Unlock** lets it be written again.
4. **Write again** asks for a new version now. A new version is also written by itself when the car''s facts change: its rates, specs, area or photos.

> Good to know: The checks refuse long dashes, sales words, the numbered company, any number that is not in the car''s facts (a price, a seat count) and equipment the facts do not list. A version that fails is asked again with the problems named; if it still fails, the page keeps its current text and it is tried again later.

## Landing pages and guides

**Settings** > **All settings**, then Search.

1. Today: the Workers AI used for search copy and in all, and IndexNow (addresses waiting and sent).
2. Car copy: every real car, who wrote its text, and whether its facts changed since.
3. Landing pages: each place and way of renting, whether it is in search, its cars and who wrote it. A page for a way of renting (monthly, SUV) goes into search once enough real cars match it (Program settings).
4. Open **Edit** on a page or a guide to change its text. Edited fields are locked. **Write again** asks for a new version; on a guide, the brief says what it must cover.

## Vehicle pages

**Settings** > **Vehicle pages**. A page for every make, model, model year and Canadian trim of every year, at carmacars.ca/cars/make/model/year/trim, with our cars below it; each trim also in every place and in 12 colours (a black 2020 Volkswagen Jetta Sportline in Mississauga, for example); every page again for sale (carmacars.ca/buy/...) and for each search term: renting (car hire), sale (financing), detailing (ceramic coating) and body shop (bumper repair), at carmacars.ca/t/term/...

1. Pages: how many pages each level and each tier has, the total, and how many are in search. Every page is in search by default; nothing needs setting up.
2. One switch per tier takes it out of search at once: **Index the place pages**, **Index the colour pages**, **Index the search term pages**, **Index the /buy pages**, **Index the detailing pages**, **Index the body shop pages**. Off, those pages stay visible but leave the sitemaps and search.
3. The places are the place list of the local search release (every city, town and neighbourhood, with GTA and country levels); until it is filled, the area landing pages. The search terms are edited with them.
4. **Financing disclaimer**: the text on financing and leasing pages. CarmaCars never says it lends or leases.
5. Database: its size against the cap the catalog and places imports keep under: the cap of the Database plan (Pro, 6,144 MB, by default; Free, 450 MB). IndexNow: the addresses sent today, where the sweep is, and any back-off; nothing to do.
6. Each page is built from data: the EPA fuel-use ratings in litres per 100 km, the cost to drive 100 km at the gas or electricity price set here, what changed from the year before, how a trim differs from the others, similar models, and the rental questions from the program settings.
7. Below the facts: our cars of that exact year, model and trim, then the same model in other years, then similar cars free now, and Request it, which sends an enquiry to Bookings > Leads.
8. Settings: **Index every page** (the default) or **Only pages that pass the rules**: makes, models with 2 or more years of data, years with one of our cars or of a popular model from 2015, trims with one of our cars. The others stay visible but out of search. Also the gas, premium and electricity prices, and how often the catalog is imported (every 30 days).
9. Canadian trims: open a model and type one line per run of years, entry trim first: 2020-2021: Comfortline, Highline, Sportline, Execline. Your lines are kept by every import; empty them to go back to the CarmaCars list. **Add trims for another model** adds a model that has none.
10. Catalog import: the last import and its counts. **Import now** asks for a new one; it runs at the next daily check, at 07:17 UTC.

> Good to know: A car joins its pages by itself once it is on the site: its make, model, year and trim are read from the car. A trim that names several (S / SE / R-Line) leaves the car on the year page only; set the car''s trim to one Canadian name to put it on the trim page.

## A car for sale

**Cars** > **Vehicles**, then the car. On the For sale card, tick **For sale**, enter the Asking price and press **Save**.

1. The car then shows at the top of its /buy pages (its make, model, year and trim) with the asking price, the only time a page says a car is for sale.
2. Untick it when the car is sold or no longer for sale: the pages say so at once.
3. "Find me this car" on the /buy pages sends a buyer lead to Sales (staff portal: **Owner leads**, Buyer leads), with a To do line.

## Search engines and business listings

**Settings** > **All settings**, then Site settings.

1. Search engines: paste the Google Search Console value (HTML tag) or the file name (HTML file), and the Bing value. The steps are on the card.
2. Business name, address and phone: the exact text for every listing, and the description and categories.
3. Business listings: press **Copy** beside each line and paste it into Google Business Profile, Bing Places, Apple Business Connect, Yelp, Yellow Pages and Facebook. Tick each one when it is done.

> Good to know: Changed pages are sent to IndexNow (Bing and the other engines that use it) by themselves. Google reads the sitemap: submit carmacars.ca/sitemap.xml once in Search Console.

## Place pages

Every place we have, from a country down to a neighbourhood, gets a page for every term people search with: renting (car hire, SUV rental, monthly car rental ...), buying help (used cars, car financing ...), detailing (ceramic coating, window tint ...) and body work (collision repair, dent repair ...). Each page is written from real data only: the distance from us, the delivery price within our reach, the nearest airport, the landmarks near it, our live cars and the places around it. A place far from Toronto says we serve the Toronto area and takes a request instead. **Settings** > **All settings**, then Search.

1. Place pages: four switches, one for each family, put the pages in search and in the sitemaps. All four are on.
2. Quality gate: off. On, only places within the delivery reach are in search, and rental pages only with a real matching car. Search engines can treat many similar pages as low value; the gate lowers that risk.
3. Delivery reach: places within this distance of our location are offered delivery. Database size cap: the places import stops before the database passes it.
4. Regions and places: every province, state and territory is on. Untick a region to take its pages and sitemaps off the site.
5. Terms and services: change a term''s title or what is true about it, point a synonym to another term (its pages then leave search), switch a term off, or add one. Give a service a starting price, or leave it empty for "price on request".

> Good to know: A region has pages once the places workflow has loaded it: GitHub, Actions, places, Run workflow, with the regions or all. The run loads Ontario first and names any region it skipped because of the size cap.

## Requests from the place pages

The buying help, detailing and body shop pages, and the pages of places beyond our reach, have a request form. Each request is a lead with a task in **To do**: detailing and body shop requests are due within an hour of opening and show in Today. Buying help pages say plainly that CarmaCars does not sell, finance or lease cars; the notice at the top is set under Place pages.

Mechanical work has pages too, under the body shop pages and listed apart as "Auto services we arrange": a mechanic, oil changes, brakes, tires and winter tires, towing, batteries and boosts, alignment, transmission and engine repair, diagnostics, inspections and the Ontario safety certificate, emissions, AC, exhaust and suspension. CarmaCars does not do this work, and the pages say so: each takes a request (a "Mechanical work to arrange" task, due within an hour of opening) and offers a rental while the car is in. They have no questions of their own; their per car pages (for each make, model, year and trim) say the same and take the same request.

## One name, address and phone

The footer, the contact page, the structured data and every business listing show the business address of Site settings. Keep it the address renters come to, and change it there only.
',
  '<p class="gd-p">The text of every car page, the landing pages for each area and way of renting, and the guides are written every day by a scheduled Claude session from the facts in the database, checked with the site&#39;s own checks and published by themselves (the website&#39;s Workers AI writer is off, so the free AI allowance stays with the staff assistant). Nobody has to type or review anything. You can still change any line; what you change is kept.</p><section class="gd-task" id="search-car-pages-landing-pages-and-guides-the-copy-of-a-car" data-gd-task><h2 class="gd-h2">The copy of a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, then the car, then its Listing tab. The same card is on the listing review.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The card says who wrote the text: a plain copy from the car&#39;s facts while the written copy is prepared (the next daily batch), then the batch (claude-batch) or Workers AI.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Every field is shown: search title and description, heading, introduction, highlights, good for, what&#39;s included, pickup and delivery, requirements, questions and the photo descriptions.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To change a field press <b class="gd-ui">Change</b>, then <b class="gd-ui">Save and lock</b>. A locked field is kept by every new version. <b class="gd-ui">Unlock</b> lets it be written again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Write again</b> asks for a new version now. A new version is also written by itself when the car&#39;s facts change: its rates, specs, area or photos.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The checks refuse long dashes, sales words, the numbered company, any number that is not in the car&#39;s facts (a price, a seat count) and equipment the facts do not list. A version that fails is asked again with the problems named; if it still fails, the page keeps its current text and it is tried again later.</div></aside></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-landing-pages-and-guides" data-gd-task><h2 class="gd-h2">Landing pages and guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, then Search.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Today: the Workers AI used for search copy and in all, and IndexNow (addresses waiting and sent).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Car copy: every real car, who wrote its text, and whether its facts changed since.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Landing pages: each place and way of renting, whether it is in search, its cars and who wrote it. A page for a way of renting (monthly, SUV) goes into search once enough real cars match it (Program settings).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Open <b class="gd-ui">Edit</b> on a page or a guide to change its text. Edited fields are locked. <b class="gd-ui">Write again</b> asks for a new version; on a guide, the brief says what it must cover.</div></li></ol></div></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-vehicle-pages" data-gd-task><h2 class="gd-h2">Vehicle pages</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Vehicle pages</b>. A page for every make, model, model year and Canadian trim of every year, at carmacars.ca/cars/make/model/year/trim, with our cars below it; each trim also in every place and in 12 colours (a black 2020 Volkswagen Jetta Sportline in Mississauga, for example); every page again for sale (carmacars.ca/buy/...) and for each search term: renting (car hire), sale (financing), detailing (ceramic coating) and body shop (bumper repair), at carmacars.ca/t/term/...</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Pages: how many pages each level and each tier has, the total, and how many are in search. Every page is in search by default; nothing needs setting up.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">One switch per tier takes it out of search at once: <b class="gd-ui">Index the place pages</b>, <b class="gd-ui">Index the colour pages</b>, <b class="gd-ui">Index the search term pages</b>, <b class="gd-ui">Index the /buy pages</b>, <b class="gd-ui">Index the detailing pages</b>, <b class="gd-ui">Index the body shop pages</b>. Off, those pages stay visible but leave the sitemaps and search.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The places are the place list of the local search release (every city, town and neighbourhood, with GTA and country levels); until it is filled, the area landing pages. The search terms are edited with them.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Financing disclaimer</b>: the text on financing and leasing pages. CarmaCars never says it lends or leases.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Database: its size against the cap the catalog and places imports keep under: the cap of the Database plan (Pro, 6,144 MB, by default; Free, 450 MB). IndexNow: the addresses sent today, where the sweep is, and any back-off; nothing to do.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Each page is built from data: the EPA fuel-use ratings in litres per 100 km, the cost to drive 100 km at the gas or electricity price set here, what changed from the year before, how a trim differs from the others, similar models, and the rental questions from the program settings.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Below the facts: our cars of that exact year, model and trim, then the same model in other years, then similar cars free now, and Request it, which sends an enquiry to Bookings &gt; Leads.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Settings: <b class="gd-ui">Index every page</b> (the default) or <b class="gd-ui">Only pages that pass the rules</b>: makes, models with 2 or more years of data, years with one of our cars or of a popular model from 2015, trims with one of our cars. The others stay visible but out of search. Also the gas, premium and electricity prices, and how often the catalog is imported (every 30 days).</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Canadian trims: open a model and type one line per run of years, entry trim first: 2020-2021: Comfortline, Highline, Sportline, Execline. Your lines are kept by every import; empty them to go back to the CarmaCars list. <b class="gd-ui">Add trims for another model</b> adds a model that has none.</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Catalog import: the last import and its counts. <b class="gd-ui">Import now</b> asks for a new one; it runs at the next daily check, at 07:17 UTC.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A car joins its pages by itself once it is on the site: its make, model, year and trim are read from the car. A trim that names several (S / SE / R-Line) leaves the car on the year page only; set the car&#39;s trim to one Canadian name to put it on the trim page.</div></aside></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-a-car-for-sale" data-gd-task><h2 class="gd-h2">A car for sale</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, then the car. On the For sale card, tick <b class="gd-ui">For sale</b>, enter the Asking price and press <b class="gd-ui">Save</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The car then shows at the top of its /buy pages (its make, model, year and trim) with the asking price, the only time a page says a car is for sale.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Untick it when the car is sold or no longer for sale: the pages say so at once.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">&quot;Find me this car&quot; on the /buy pages sends a buyer lead to Sales (staff portal: <b class="gd-ui">Owner leads</b>, Buyer leads), with a To do line.</div></li></ol></div></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-search-engines-and-business-listings" data-gd-task><h2 class="gd-h2">Search engines and business listings</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, then Site settings.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Search engines: paste the Google Search Console value (HTML tag) or the file name (HTML file), and the Bing value. The steps are on the card.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Business name, address and phone: the exact text for every listing, and the description and categories.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Business listings: press <b class="gd-ui">Copy</b> beside each line and paste it into Google Business Profile, Bing Places, Apple Business Connect, Yelp, Yellow Pages and Facebook. Tick each one when it is done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Changed pages are sent to IndexNow (Bing and the other engines that use it) by themselves. Google reads the sitemap: submit carmacars.ca/sitemap.xml once in Search Console.</div></aside></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-place-pages" data-gd-task><h2 class="gd-h2">Place pages</h2><p class="gd-p">Every place we have, from a country down to a neighbourhood, gets a page for every term people search with: renting (car hire, SUV rental, monthly car rental ...), buying help (used cars, car financing ...), detailing (ceramic coating, window tint ...) and body work (collision repair, dent repair ...). Each page is written from real data only: the distance from us, the delivery price within our reach, the nearest airport, the landmarks near it, our live cars and the places around it. A place far from Toronto says we serve the Toronto area and takes a request instead. <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, then Search.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Place pages: four switches, one for each family, put the pages in search and in the sitemaps. All four are on.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Quality gate: off. On, only places within the delivery reach are in search, and rental pages only with a real matching car. Search engines can treat many similar pages as low value; the gate lowers that risk.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Delivery reach: places within this distance of our location are offered delivery. Database size cap: the places import stops before the database passes it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Regions and places: every province, state and territory is on. Untick a region to take its pages and sitemaps off the site.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Terms and services: change a term&#39;s title or what is true about it, point a synonym to another term (its pages then leave search), switch a term off, or add one. Give a service a starting price, or leave it empty for &quot;price on request&quot;.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A region has pages once the places workflow has loaded it: GitHub, Actions, places, Run workflow, with the regions or all. The run loads Ontario first and names any region it skipped because of the size cap.</div></aside></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-requests-from-the-place-pages" data-gd-task><h2 class="gd-h2">Requests from the place pages</h2><p class="gd-p">The buying help, detailing and body shop pages, and the pages of places beyond our reach, have a request form. Each request is a lead with a task in <b class="gd-ui">To do</b>: detailing and body shop requests are due within an hour of opening and show in Today. Buying help pages say plainly that CarmaCars does not sell, finance or lease cars; the notice at the top is set under Place pages.</p><p class="gd-p">Mechanical work has pages too, under the body shop pages and listed apart as &quot;Auto services we arrange&quot;: a mechanic, oil changes, brakes, tires and winter tires, towing, batteries and boosts, alignment, transmission and engine repair, diagnostics, inspections and the Ontario safety certificate, emissions, AC, exhaust and suspension. CarmaCars does not do this work, and the pages say so: each takes a request (a &quot;Mechanical work to arrange&quot; task, due within an hour of opening) and offers a rental while the car is in. They have no questions of their own; their per car pages (for each make, model, year and trim) say the same and take the same request.</p></section><section class="gd-task" id="search-car-pages-landing-pages-and-guides-one-name-address-and-phone" data-gd-task><h2 class="gd-h2">One name, address and phone</h2><p class="gd-p">The footer, the contact page, the structured data and every business listing show the business address of Site settings. Keep it the address renters come to, and change it there only.</p></section>');
select app.guide_release_section('admin', 'assistant', 'chapter', 'the-investor-deck', 'The assistant answers questions from live data and prepares changes for you. It works only through the same steps as the screens, with your own permissions: it cannot see or do anything you could not do yourself. Nothing changes until you confirm.

## Open it

Press **Assistant** at the top of the menu, or press Ctrl and / together (Cmd and / on a Mac). Esc closes it.

1. Type a question or what you want done, in your own words, and press Enter. Examples: "What needs doing today?", "Who has the Tesla?", "Is the Corolla free from 2026-11-02 to 2026-11-04?", "Find booking R-000123".
2. Answers come as cards with links: open one to go straight to the screen.
3. If something is missing or more than one thing matches, it asks and lists the choices. Press the one you mean.

## Changes: a card to confirm

1. Ask for a change, for example "Record a $900 e-Transfer on INV-1053 dated 2026-10-15 reference CA12345".
2. The assistant shows a card: "Record a $900 e-Transfer on INV-1053 for Karan Vakil, dated Oct 15?". Read it, then press **Confirm** or **Cancel**.
3. Confirmed, it runs the same step as the screen and its pop-up, with the same checks. If the step is not allowed for you, or a detail is wrong, it says why and nothing changes.
4. Every change is in the audit log under your name, marked "via assistant". A card older than 30 minutes no longer runs: ask again.

When the insurer''s email arrives, say so: "The insurer confirmed CC-7F3A on 2026-10-20". The card marks the car insured as To do''s Insurer confirmed does, from the date of the email. A car is found by its name, its plate or its car code (CC- and four characters, on the car page and in the chat).

Messages: ask it to draft a message to a renter or an owner. It writes the text; press **Copy**, open the conversation and send it yourself.

> Tip: When the day''s included AI usage is used, the assistant says it is unavailable until tomorrow. Everything still works from the screens and pop-ups.
', 'Assistant', 'Ask about today, bookings, cars and money; send offers and add rentals; confirm the changes it prepares.',
  'The assistant answers questions from live data and prepares changes for you. It works only through the same steps as the screens, with your own permissions: it cannot see or do anything you could not do yourself. Nothing changes until you confirm.

## Open it

Press **Assistant** at the top of the menu, or press Ctrl and / together (Cmd and / on a Mac). Esc closes it.

1. Type a question or what you want done, in your own words, and press Enter. Examples: "What needs doing today?", "Who has the Tesla?", "Is the Corolla free from 2026-11-02 to 2026-11-04?", "Find booking R-000123".
2. Answers come as cards with links: open one to go straight to the screen.
3. If something is missing or more than one thing matches, it asks and lists the choices. Press the one you mean.

## Changes: a card to confirm

1. Ask for a change, for example "Record a $900 e-Transfer on INV-1053 dated 2026-10-15 reference CA12345".
2. The assistant shows a card: "Record a $900 e-Transfer on INV-1053 for Karan Vakil, dated Oct 15?". Read it, then press **Confirm** or **Cancel**.
3. Confirmed, it runs the same step as the screen and its pop-up, with the same checks. If the step is not allowed for you, or a detail is wrong, it says why and nothing changes.
4. Every change is in the audit log under your name, marked "via assistant". A card older than 30 minutes no longer runs: ask again.

When the insurer''s email arrives, say so: "The insurer confirmed CC-7F3A on 2026-10-20". The card marks the car insured as To do''s Insurer confirmed does, from the date of the email. A car is found by its name, its plate or its car code (CC- and four characters, on the car page and in the chat).

Messages: ask it to draft a message to a renter or an owner. It writes the text; press **Copy**, open the conversation and send it yourself.

## Offers, rentals and what is owed

1. Send an offer: "Send an offer for the Corolla to jane@example.com, Nov 2 10:00 to Nov 4 10:00, deposit in cash". A customer on file is found by name, email or phone; a new customer needs the full name, email, mobile and date of birth.
2. The card shows everything before anything is made: the customer, the car, the dates, each price line, the HST, what is due at booking, the deposit, how the rental and the deposit are paid, and how the offer is sent. It is priced exactly as **Send an offer** prices it. Press **Confirm** to make and send it, or **Cancel**.
3. Add a rental: "Add a rental of the Corolla for jane@example.com, Nov 2 10:00 to Nov 4 10:00, paid by e-Transfer ref CA123, deposit in cash, signed on paper". The card lists the price lines and the payments the same way.
4. Free cars: "Which cars are free from 2026-11-02 to 2026-11-04?" lists every bookable car with its rates, published or not.
5. What is owed: "What does booking R-000123 owe?" or "What does Jane Doe owe?" shows the rental, fees and later charges still open, and the deposit.
6. A payment on a booking is recorded by part: "Record a $200 e-Transfer on booking R-000123 for the fees, ref CA124".
7. A booking made or paid through the assistant says so in its history: "Offer made with the staff assistant by" and your name.

> Tip: The assistant keeps 70% of the day''s free AI allowance for itself, so it works all day. When the whole allowance is used, it says how much was used and that it is back at midnight, Toronto time. Everything still works from the screens and pop-ups.
',
  '<p class="gd-p">The assistant answers questions from live data and prepares changes for you. It works only through the same steps as the screens, with your own permissions: it cannot see or do anything you could not do yourself. Nothing changes until you confirm.</p><section class="gd-task" id="assistant-open-it" data-gd-task><h2 class="gd-h2">Open it</h2><p class="gd-p">Press <b class="gd-ui">Assistant</b> at the top of the menu, or press Ctrl and / together (Cmd and / on a Mac). Esc closes it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type a question or what you want done, in your own words, and press Enter. Examples: &quot;What needs doing today?&quot;, &quot;Who has the Tesla?&quot;, &quot;Is the Corolla free from 2026-11-02 to 2026-11-04?&quot;, &quot;Find booking R-000123&quot;.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Answers come as cards with links: open one to go straight to the screen.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">If something is missing or more than one thing matches, it asks and lists the choices. Press the one you mean.</div></li></ol></div></section><section class="gd-task" id="assistant-changes-a-card-to-confirm" data-gd-task><h2 class="gd-h2">Changes: a card to confirm</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Ask for a change, for example &quot;Record a $900 e-Transfer on INV-1053 dated 2026-10-15 reference CA12345&quot;.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The assistant shows a card: &quot;Record a $900 e-Transfer on INV-1053 for Karan Vakil, dated Oct 15?&quot;. Read it, then press <b class="gd-ui">Confirm</b> or <b class="gd-ui">Cancel</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Confirmed, it runs the same step as the screen and its pop-up, with the same checks. If the step is not allowed for you, or a detail is wrong, it says why and nothing changes.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Every change is in the audit log under your name, marked &quot;via assistant&quot;. A card older than 30 minutes no longer runs: ask again.</div></li></ol></div><p class="gd-p">When the insurer&#39;s email arrives, say so: &quot;The insurer confirmed CC-7F3A on 2026-10-20&quot;. The card marks the car insured as To do&#39;s Insurer confirmed does, from the date of the email. A car is found by its name, its plate or its car code (CC- and four characters, on the car page and in the chat).</p><p class="gd-p">Messages: ask it to draft a message to a renter or an owner. It writes the text; press <b class="gd-ui">Copy</b>, open the conversation and send it yourself.</p></section><section class="gd-task" id="assistant-offers-rentals-and-what-is-owed" data-gd-task><h2 class="gd-h2">Offers, rentals and what is owed</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Send an offer: &quot;Send an offer for the Corolla to jane@example.com, Nov 2 10:00 to Nov 4 10:00, deposit in cash&quot;. A customer on file is found by name, email or phone; a new customer needs the full name, email, mobile and date of birth.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The card shows everything before anything is made: the customer, the car, the dates, each price line, the HST, what is due at booking, the deposit, how the rental and the deposit are paid, and how the offer is sent. It is priced exactly as <b class="gd-ui">Send an offer</b> prices it. Press <b class="gd-ui">Confirm</b> to make and send it, or <b class="gd-ui">Cancel</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Add a rental: &quot;Add a rental of the Corolla for jane@example.com, Nov 2 10:00 to Nov 4 10:00, paid by e-Transfer ref CA123, deposit in cash, signed on paper&quot;. The card lists the price lines and the payments the same way.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Free cars: &quot;Which cars are free from 2026-11-02 to 2026-11-04?&quot; lists every bookable car with its rates, published or not.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">What is owed: &quot;What does booking R-000123 owe?&quot; or &quot;What does Jane Doe owe?&quot; shows the rental, fees and later charges still open, and the deposit.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A payment on a booking is recorded by part: &quot;Record a $200 e-Transfer on booking R-000123 for the fees, ref CA124&quot;.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">A booking made or paid through the assistant says so in its history: &quot;Offer made with the staff assistant by&quot; and your name.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The assistant keeps 70% of the day&#39;s free AI allowance for itself, so it works all day. When the whole allowance is used, it says how much was used and that it is back at midnight, Toronto time. Everything still works from the screens and pop-ups.</div></aside></section>');
select app.guide_release_section('admin', 'usage-and-paid-usage', 'chapter', 'assistant', 'The plans CarmaCars runs on include a free allowance: AI, the website, image transformations, emails, the database and storage. When an allowance runs out, AI and photo features pause with a short message until it resets, and you are asked before anything is paid.

## The alerts

At 80% of an allowance you get one quiet card on **To do** and one email to the alert address. When it is used up, a second card and email.

1. A used-up AI or image allowance shows "Included ... used up for today: Allow paid usage". Press **Allow paid usage** to see what continuing costs at the current rates.
2. Choose until the end of today or this month, type the most it may cost (for example $1), and press the Allow button. Or press Keep paused.
3. Nobody answering keeps it paused: nothing is charged. Live chat goes to a person, AI copy waits with the template text, Turo emails are read by the rules, photos keep their original background, the assistant rests.
4. The website and the portals are never paused (that would stop bookings): their card shows the estimated cost, usually cents.

## Settings > Usage

Open **Settings**, then **Usage**: every service, used against included, when it resets, paid usage and the last 30 days.

1. Press **Change the allowance** after a plan change (for example a Supabase or Resend upgrade).
2. Supabase egress is not readable automatically: press **Enter a figure** with the number from the Supabase dashboard.
3. Emails cannot be paid on the free plan: when the daily or monthly count is used, booking, payment and sign-in emails still go first and the others wait. A banner on To do says so.
', 'Usage and paid usage', 'Included allowances, the 80% and used-up alerts, Workers AI by feature (never paid), allowing paid usage for photos, what pauses and what never does.',
  'The plans CarmaCars runs on include a free allowance: AI, the website, image transformations, emails, the database and storage. When an allowance runs out, AI and photo features pause with a short message until it resets. Workers AI never runs into paid usage; for photos you are asked before anything is paid.

## The alerts

At 80% of an allowance you get one quiet card on **To do** and one email to the alert address. When it is used up, a second card and email.

1. Workers AI used up shows "Stopped for today, never paid": it starts again at midnight, Toronto time. There is nothing to allow.
2. A used-up image allowance shows "Included ... used up for this month: Allow paid usage". Press **Allow paid usage** to see what continuing costs at the current rates.
3. Choose until the end of today or this month, type the most it may cost (for example $1), and press the Allow button. Or press Keep paused.
4. Nobody answering keeps it paused: nothing is charged. Live chat goes to a person, AI copy waits with the template text, Turo emails are read by the rules, photos keep their original background, the assistant rests.
5. The website and the portals are never paused (that would stop bookings): their card shows the estimated cost, usually cents.

## Settings > Usage

Open **Settings**, then **Usage**: every service, used against included, when it resets, paid usage and the last 30 days.

1. Workers AI by feature, at the top: the neurons each feature used today and in the last 7 days (the staff assistant, visitor chat, the phone line, search copy, listing copy, guide upkeep, Turo emails, the readers), and what each share has left now. Use Cloudflare counted beyond the app''s own record shows as Unmetered.
2. The day is shared in three: 70% is kept for the staff assistant; visitor chat, the phone line and the readers share the rest; background writing (search copy, listing copy, guide rewrites, Turo emails) gets 10%, and from 9 pm what is left of the day, less a small cushion for the assistant.
3. Press **Change the shares** to change the assistant''s reserve, the background share, the release hour or the cushion.
4. Press **Change the allowance** after a plan change (for example a Supabase or Resend upgrade).
5. Supabase egress is not readable automatically: press **Enter a figure** with the number from the Supabase dashboard.
6. Emails cannot be paid on the free plan: when the daily or monthly count is used, booking, payment and sign-in emails still go first and the others wait. A banner on To do says so.
',
  '<p class="gd-p">The plans CarmaCars runs on include a free allowance: AI, the website, image transformations, emails, the database and storage. When an allowance runs out, AI and photo features pause with a short message until it resets. Workers AI never runs into paid usage; for photos you are asked before anything is paid.</p><section class="gd-task" id="usage-and-paid-usage-the-alerts" data-gd-task><h2 class="gd-h2">The alerts</h2><p class="gd-p">At 80% of an allowance you get one quiet card on <b class="gd-ui">To do</b> and one email to the alert address. When it is used up, a second card and email.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Workers AI used up shows &quot;Stopped for today, never paid&quot;: it starts again at midnight, Toronto time. There is nothing to allow.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A used-up image allowance shows &quot;Included ... used up for this month: Allow paid usage&quot;. Press <b class="gd-ui">Allow paid usage</b> to see what continuing costs at the current rates.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Choose until the end of today or this month, type the most it may cost (for example $1), and press the Allow button. Or press Keep paused.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Nobody answering keeps it paused: nothing is charged. Live chat goes to a person, AI copy waits with the template text, Turo emails are read by the rules, photos keep their original background, the assistant rests.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The website and the portals are never paused (that would stop bookings): their card shows the estimated cost, usually cents.</div></li></ol></div></section><section class="gd-task" id="usage-and-paid-usage-settings-usage" data-gd-task><h2 class="gd-h2">Settings &gt; Usage</h2><p class="gd-p">Open <b class="gd-ui">Settings</b>, then <b class="gd-ui">Usage</b>: every service, used against included, when it resets, paid usage and the last 30 days.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Workers AI by feature, at the top: the neurons each feature used today and in the last 7 days (the staff assistant, visitor chat, the phone line, search copy, listing copy, guide upkeep, Turo emails, the readers), and what each share has left now. Use Cloudflare counted beyond the app&#39;s own record shows as Unmetered.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The day is shared in three: 70% is kept for the staff assistant; visitor chat, the phone line and the readers share the rest; background writing (search copy, listing copy, guide rewrites, Turo emails) gets 10%, and from 9 pm what is left of the day, less a small cushion for the assistant.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Change the shares</b> to change the assistant&#39;s reserve, the background share, the release hour or the cushion.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Change the allowance</b> after a plan change (for example a Supabase or Resend upgrade).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Supabase egress is not readable automatically: press <b class="gd-ui">Enter a figure</b> with the number from the Supabase dashboard.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Emails cannot be paid on the free plan: when the daily or monthly count is used, booking, payment and sign-in emails still go first and the others wait. A banner on To do says so.</div></li></ol></div></section>');
select app.guide_release_section('va', 'assistant', 'chapter', 'add-ons', 'The assistant answers questions from live data and prepares changes for you. It works only through the same steps as the screens, with your own permissions: it cannot see or do anything you could not do yourself. Nothing changes until you confirm.

## Open it

Press **Assistant** at the top of the menu, or press Ctrl and / together (Cmd and / on a Mac). Esc closes it.

1. Type a question or what you want done, in your own words, and press Enter. Examples: "What needs doing today?", "Who has the Tesla?", "Is the Corolla free from 2026-11-02 to 2026-11-04?", "Find booking R-000123".
2. Answers come as cards with links: open one to go straight to the screen.
3. If something is missing or more than one thing matches, it asks and lists the choices. Press the one you mean.

## Changes: a card to confirm

1. Ask for a change, for example "Record a $900 e-Transfer on INV-1053 dated 2026-10-15 reference CA12345".
2. The assistant shows a card: "Record a $900 e-Transfer on INV-1053 for Karan Vakil, dated Oct 15?". Read it, then press **Confirm** or **Cancel**.
3. Confirmed, it runs the same step as the screen and its pop-up, with the same checks. If the step is not allowed for you, or a detail is wrong, it says why and nothing changes.
4. Every change is in the audit log under your name, marked "via assistant". A card older than 30 minutes no longer runs: ask again.

Messages: ask it to draft a message to a renter or an owner. It writes the text; press **Copy**, open the conversation and send it yourself.

> Tip: When the day''s included AI usage is used, the assistant says it is unavailable until tomorrow. Everything still works from the screens and pop-ups.
', 'Assistant', 'Ask about today, bookings, cars and money; send offers and add rentals; confirm the changes it prepares.',
  'The assistant answers questions from live data and prepares changes for you. It works only through the same steps as the screens, with your own permissions: it cannot see or do anything you could not do yourself. Nothing changes until you confirm.

## Open it

Press **Assistant** at the top of the menu, or press Ctrl and / together (Cmd and / on a Mac). Esc closes it.

1. Type a question or what you want done, in your own words, and press Enter. Examples: "What needs doing today?", "Who has the Tesla?", "Is the Corolla free from 2026-11-02 to 2026-11-04?", "Find booking R-000123".
2. Answers come as cards with links: open one to go straight to the screen.
3. If something is missing or more than one thing matches, it asks and lists the choices. Press the one you mean.

## Changes: a card to confirm

1. Ask for a change, for example "Record a $900 e-Transfer on INV-1053 dated 2026-10-15 reference CA12345".
2. The assistant shows a card: "Record a $900 e-Transfer on INV-1053 for Karan Vakil, dated Oct 15?". Read it, then press **Confirm** or **Cancel**.
3. Confirmed, it runs the same step as the screen and its pop-up, with the same checks. If the step is not allowed for you, or a detail is wrong, it says why and nothing changes.
4. Every change is in the audit log under your name, marked "via assistant". A card older than 30 minutes no longer runs: ask again.

Messages: ask it to draft a message to a renter or an owner. It writes the text; press **Copy**, open the conversation and send it yourself.

## Offers, rentals and what is owed (customer service and sales)

1. Send an offer: "Send an offer for the Corolla to jane@example.com, Nov 2 10:00 to Nov 4 10:00". A customer on file is found by name, email or phone; a new customer needs the full name, email, mobile and date of birth. Say "I found this client" when you did, so the booking counts for you.
2. The card shows the customer, the car, the dates, each price line, the HST, what is due at booking, the deposit, how it is paid and how the offer is sent, priced as **Send an offer** prices it. Press **Confirm** to make and send it, or **Cancel**.
3. Add a rental the same way: "Add a rental of the Corolla for jane@example.com, Nov 2 10:00 to Nov 4 10:00, paid by e-Transfer ref CA123, deposit in cash".
4. What is owed: "What does booking R-000123 owe?" shows the rental, fees and later charges still open, and the deposit. Finance sees it too.
5. Only what your function may do from the screens is offered; the booking''s history says it was made with the staff assistant, with your name.

> Tip: The assistant keeps 70% of the day''s free AI allowance for itself, so it works all day. When the whole allowance is used, it says how much was used and that it is back at midnight, Toronto time. Everything still works from the screens and pop-ups.
',
  '<p class="gd-p">The assistant answers questions from live data and prepares changes for you. It works only through the same steps as the screens, with your own permissions: it cannot see or do anything you could not do yourself. Nothing changes until you confirm.</p><section class="gd-task" id="assistant-open-it" data-gd-task><h2 class="gd-h2">Open it</h2><p class="gd-p">Press <b class="gd-ui">Assistant</b> at the top of the menu, or press Ctrl and / together (Cmd and / on a Mac). Esc closes it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type a question or what you want done, in your own words, and press Enter. Examples: &quot;What needs doing today?&quot;, &quot;Who has the Tesla?&quot;, &quot;Is the Corolla free from 2026-11-02 to 2026-11-04?&quot;, &quot;Find booking R-000123&quot;.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Answers come as cards with links: open one to go straight to the screen.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">If something is missing or more than one thing matches, it asks and lists the choices. Press the one you mean.</div></li></ol></div></section><section class="gd-task" id="assistant-changes-a-card-to-confirm" data-gd-task><h2 class="gd-h2">Changes: a card to confirm</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Ask for a change, for example &quot;Record a $900 e-Transfer on INV-1053 dated 2026-10-15 reference CA12345&quot;.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The assistant shows a card: &quot;Record a $900 e-Transfer on INV-1053 for Karan Vakil, dated Oct 15?&quot;. Read it, then press <b class="gd-ui">Confirm</b> or <b class="gd-ui">Cancel</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Confirmed, it runs the same step as the screen and its pop-up, with the same checks. If the step is not allowed for you, or a detail is wrong, it says why and nothing changes.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Every change is in the audit log under your name, marked &quot;via assistant&quot;. A card older than 30 minutes no longer runs: ask again.</div></li></ol></div><p class="gd-p">Messages: ask it to draft a message to a renter or an owner. It writes the text; press <b class="gd-ui">Copy</b>, open the conversation and send it yourself.</p></section><section class="gd-task" id="assistant-offers-rentals-and-what-is-owed-customer-service-and-sales" data-gd-task><h2 class="gd-h2">Offers, rentals and what is owed (customer service and sales)</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Send an offer: &quot;Send an offer for the Corolla to jane@example.com, Nov 2 10:00 to Nov 4 10:00&quot;. A customer on file is found by name, email or phone; a new customer needs the full name, email, mobile and date of birth. Say &quot;I found this client&quot; when you did, so the booking counts for you.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The card shows the customer, the car, the dates, each price line, the HST, what is due at booking, the deposit, how it is paid and how the offer is sent, priced as <b class="gd-ui">Send an offer</b> prices it. Press <b class="gd-ui">Confirm</b> to make and send it, or <b class="gd-ui">Cancel</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Add a rental the same way: &quot;Add a rental of the Corolla for jane@example.com, Nov 2 10:00 to Nov 4 10:00, paid by e-Transfer ref CA123, deposit in cash&quot;.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">What is owed: &quot;What does booking R-000123 owe?&quot; shows the rental, fees and later charges still open, and the deposit. Finance sees it too.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Only what your function may do from the screens is offered; the booking&#39;s history says it was made with the staff assistant, with your name.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The assistant keeps 70% of the day&#39;s free AI allowance for itself, so it works all day. When the whole allowance is used, it says how much was used and that it is back at midnight, Toronto time. Everything still works from the screens and pop-ups.</div></aside></section>');
-- GUIDES 0133 END
