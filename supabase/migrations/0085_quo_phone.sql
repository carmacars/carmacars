-- 0085_quo_phone.sql
-- The CarmaCars business phone line on Quo (formerly OpenPhone) in the platform (docs/changes/2026-10-21-quo-phone.md).
--
--   1. Every call and text on the CarmaCars Quo number arrives by webhook (web/src/app/api/webhooks/quo) and is kept
--      here: phone_threads (one per outside number) and phone_activity (one row per call or text). Each number is
--      matched to a staff member, a renter (and their current booking), an owner or a lead (discount game claims, chat
--      visitors who gave a phone); an unmatched number is an "Unknown caller" with Create lead and Link to a renter.
--   2. A missed call: one automatic text back from the Quo number (Program settings, Phone and texts), at most once per
--      number per phone_missed_call_text_hours (12), and a task for the person on duty in the chosen function (the
--      Admins' queue when nobody holds that function). In the site check's quiet hours the task is due when they end.
--   3. Texts in the Live chat inbox (Admin > Bookings > Live chat, Texts and calls; the assistants' Live chat): threads
--      by number, staff replies sent through Quo from the CarmaCars number, AI drafts within a daily neuron allowance.
--      Nothing the AI writes is ever sent by itself; the only automatic text is the missed-call text.
--   4. Booking texts beside the existing emails (offer sent, payment confirmed, payment received, pickup tomorrow, return
--      reminder, payment link): one text for each such renter email, to renters with a mobile number who did not opt
--      out. STOP (and Quo's own carrier opt-out) stops them; START allows them again. Transactional only.
--   5. Quo's call summaries, transcripts, recordings and voicemails on the call; a one-line AI summary when Quo has none.
--   6. A caller or texter who gave the same phone in live chat or a discount game is linked to their browser, so staff
--      see the visit on the thread.
--   7. The privacy policy: section 1, section 6 and one paragraph in section 10.
--   8. Retention: with the rental records for renters, owners and bookings; otherwise phone_keep_months (12).
-- Everything is a Program setting and on by default. The CarmaCars number is site_settings.phone, never written here.

-- ================================================================ 1. settings
create or replace function app.phone_text_ok(p text) returns boolean
language sql immutable as $$
  select p is not null and length(btrim(p)) between 1 and 480 and strpos(p, chr(8212)) = 0 and strpos(p, chr(8211)) = 0 and strpos(p, 'CarmaCars') > 0
$$;
comment on function app.phone_text_ok(text) is 'A text template: 1 to 480 characters, no long dashes, and it names CarmaCars.';

alter table program_settings
  add column if not exists phone_enabled boolean not null default true,
  add column if not exists phone_record_calls boolean not null default true,
  add column if not exists phone_record_texts boolean not null default true,
  add column if not exists phone_missed_call_text_enabled boolean not null default true,
  add column if not exists phone_missed_call_text text not null default 'Sorry we missed your call. How can we help? Reply here, or book at carmacars.ca. CarmaCars',
  add column if not exists phone_missed_call_text_hours integer not null default 12 check (phone_missed_call_text_hours between 1 and 168),
  add column if not exists phone_missed_call_task boolean not null default true,
  add column if not exists phone_missed_call_queue text not null default 'cs' check (phone_missed_call_queue in ('cs', 'sales', 'fleet', 'finance', 'admin')),
  add column if not exists phone_ai_drafts boolean not null default true,
  add column if not exists phone_ai_summaries boolean not null default true,
  add column if not exists phone_ai_daily_neurons integer not null default 1500 check (phone_ai_daily_neurons between 0 and 1000000),
  add column if not exists phone_link_visitors boolean not null default true,
  add column if not exists phone_keep_months integer not null default 12 check (phone_keep_months between 1 and 120),
  add column if not exists phone_sms_booking boolean not null default true,
  add column if not exists phone_sms_quiet_hours boolean not null default true,
  add column if not exists phone_sms_stop_line boolean not null default true,
  add column if not exists phone_sms_offer_sent boolean not null default true,
  add column if not exists phone_sms_offer_sent_text text not null default 'Hi {first_name}, your CarmaCars offer {booking} for the {car} is ready. Review and pay: {link}',
  add column if not exists phone_sms_payment_confirmed boolean not null default true,
  add column if not exists phone_sms_payment_confirmed_text text not null default 'Hi {first_name}, payment received. Your CarmaCars booking {booking} is confirmed for {pickup}. Details: {link}',
  add column if not exists phone_sms_payment_received boolean not null default true,
  add column if not exists phone_sms_payment_received_text text not null default 'Hi {first_name}, we received your payment of {amount} for booking {booking}. Thank you. CarmaCars',
  add column if not exists phone_sms_pickup_tomorrow boolean not null default true,
  add column if not exists phone_sms_pickup_tomorrow_text text not null default 'Hi {first_name}, a reminder that your CarmaCars pickup for {booking} is tomorrow, {pickup}. Details: {link}',
  add column if not exists phone_sms_return_reminder boolean not null default true,
  add column if not exists phone_sms_return_reminder_text text not null default 'Hi {first_name}, a reminder to return the {car} ({booking}) by {return}. Questions? Reply here. CarmaCars',
  add column if not exists phone_sms_payment_link boolean not null default true,
  add column if not exists phone_sms_payment_link_text text not null default 'Hi {first_name}, your CarmaCars booking {booking} is waiting for payment. Pay here to confirm it: {link}';

alter table program_settings drop constraint if exists program_settings_phone_texts_check;
alter table program_settings add constraint program_settings_phone_texts_check check (
  app.phone_text_ok(phone_missed_call_text) and app.phone_text_ok(phone_sms_offer_sent_text) and app.phone_text_ok(phone_sms_payment_confirmed_text)
  and app.phone_text_ok(phone_sms_payment_received_text) and app.phone_text_ok(phone_sms_pickup_tomorrow_text)
  and app.phone_text_ok(phone_sms_return_reminder_text) and app.phone_text_ok(phone_sms_payment_link_text));

comment on column program_settings.phone_enabled is 'Phone and texts (Quo): record calls and texts on the CarmaCars number and use the features below. Off: webhooks are acknowledged and nothing is kept or sent.';
comment on column program_settings.phone_record_calls is 'Phone and texts: keep each call (time, length, status, recording, transcript and summary).';
comment on column program_settings.phone_record_texts is 'Phone and texts: keep each text and show it in the inbox.';
comment on column program_settings.phone_missed_call_text_enabled is 'Phone and texts: text a caller back after a missed call (the template below), once per number in the hours below.';
comment on column program_settings.phone_missed_call_text is 'Phone and texts: the missed-call text. Short, no long dashes, names CarmaCars.';
comment on column program_settings.phone_missed_call_text_hours is 'Phone and texts: at most one missed-call text per number in this many hours (12).';
comment on column program_settings.phone_missed_call_task is 'Phone and texts: a "Missed call" task for the person on duty (one open task per number).';
comment on column program_settings.phone_missed_call_queue is 'Phone and texts: the function that calls back (cs, sales, fleet, finance or admin). With nobody holding it, the Admins get the task.';
comment on column program_settings.phone_ai_drafts is 'Phone and texts: Suggest a reply in the inbox (Workers AI). A draft is never sent by itself.';
comment on column program_settings.phone_ai_summaries is 'Phone and texts: a one-line AI summary of a call transcript when Quo gives no summary.';
comment on column program_settings.phone_ai_daily_neurons is 'Phone and texts: Workers AI neurons a day for drafts and summaries (also stopped by the all-use cap of Live chat).';
comment on column program_settings.phone_link_visitors is 'Phone and texts: link a caller who gave the same phone in live chat or a discount game to their visit on the site.';
comment on column program_settings.phone_keep_months is 'Phone and texts: calls and texts not linked to a renter, owner or booking are deleted after this many months (the privacy policy says 12).';
comment on column program_settings.phone_sms_booking is 'Phone and texts: booking texts beside the emails (the moments below), to renters with a mobile number who did not opt out.';
comment on column program_settings.phone_sms_quiet_hours is 'Phone and texts: hold booking texts during the site check''s quiet hours and send them when the quiet hours end.';
comment on column program_settings.phone_sms_stop_line is 'Phone and texts: add "Reply STOP to opt out." to the first booking text to a number.';

-- the settings group in Admin: "Phone and texts" (web/src/app/admin/settings/[section]/page.tsx)

-- ================================================================ 2. tables
create table if not exists quo_config (
  singleton        boolean primary key default true check (singleton),
  phone_number_id  text,                        -- the Quo inbox of the CarmaCars number (PN...), found by the deploy
  webhook_id       text,
  checked_at       timestamptz,
  note             text
);
insert into quo_config (singleton) values (true) on conflict do nothing;
comment on table quo_config is 'Quo (0085): the inbox id of the CarmaCars number and the webhook, written by the deploy (scripts/deploy/quo.mjs). Never a key.';

create table if not exists phone_threads (
  id               uuid primary key default gen_random_uuid(),
  number           text not null unique check (number ~ '^\+[1-9][0-9]{7,14}$'),
  match_kind       text not null default 'unknown' check (match_kind in ('staff', 'renter', 'owner', 'lead', 'unknown')),
  name             text,
  renter_id        uuid references renters (id) on delete set null,
  owner_id         uuid references owners (id) on delete set null,
  lead_id          uuid references leads (id) on delete set null,
  staff_user_id    uuid references users (id) on delete set null,
  booking_id       uuid references bookings (id) on delete set null,
  game_claim_id    uuid references game_claims (id) on delete set null,
  chat_id          uuid references chat_conversations (id) on delete set null,
  visitor_id       uuid,
  manual           boolean not null default false,       -- linked by staff: the automatic match no longer changes it
  linked_by        uuid references users (id),
  linked_at        timestamptz,
  last_at          timestamptz,
  last_preview     text,
  last_direction   text check (last_direction in ('in', 'out')),
  unread           integer not null default 0 check (unread >= 0),
  staff_read_at    timestamptz,
  opted_out_at     timestamptz,
  opt_out_source   text check (opt_out_source in ('stop', 'carrier', 'staff')),
  last_missed_text_at timestamptz,
  quo_conversation_id text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists phone_threads_last_idx on phone_threads (last_at desc);
create index if not exists phone_threads_renter_idx on phone_threads (renter_id) where renter_id is not null;
create index if not exists phone_threads_owner_idx on phone_threads (owner_id) where owner_id is not null;
create index if not exists phone_threads_lead_idx on phone_threads (lead_id) where lead_id is not null;
create trigger phone_threads_updated before update on phone_threads for each row execute function app.set_updated_at();
comment on table phone_threads is 'Quo (0085): one outside phone number that called or texted the CarmaCars number, or that we texted, and who it is.';

create table if not exists phone_activity (
  id               uuid primary key default gen_random_uuid(),
  thread_id        uuid not null references phone_threads (id) on delete cascade,
  kind             text not null check (kind in ('call', 'text')),
  direction        text not null check (direction in ('in', 'out')),
  quo_id           text unique,                   -- the call or message id (AC...)
  quo_conversation_id text,
  quo_user_id      text,
  status           text,
  body             text,
  media            jsonb not null default '[]'::jsonb,
  error_code       text,
  started_at       timestamptz not null default now(),
  answered_at      timestamptz,
  ended_at         timestamptz,
  duration_seconds integer check (duration_seconds >= 0),
  missed           boolean not null default false,
  missed_handled   boolean not null default false,
  voicemail_text   text,
  voicemail_url    text,
  recordings       jsonb not null default '[]'::jsonb,
  quo_summary      jsonb,                          -- Quo's summary lines
  next_steps       jsonb,
  transcript       jsonb,                          -- [{who, text, start, end}]
  ai_summary       text,
  summary_due_at   timestamptz,
  renter_id        uuid references renters (id) on delete set null,
  owner_id         uuid references owners (id) on delete set null,
  lead_id          uuid references leads (id) on delete set null,
  staff_user_id    uuid references users (id) on delete set null,
  booking_id       uuid references bookings (id) on delete set null,
  sent_by          uuid references users (id) on delete set null,
  outbox_id        uuid,
  sms_kind         text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists phone_activity_thread_idx on phone_activity (thread_id, started_at desc);
create index if not exists phone_activity_renter_idx on phone_activity (renter_id, started_at desc) where renter_id is not null;
create index if not exists phone_activity_booking_idx on phone_activity (booking_id, started_at desc) where booking_id is not null;
create index if not exists phone_activity_owner_idx on phone_activity (owner_id) where owner_id is not null;
create index if not exists phone_activity_lead_idx on phone_activity (lead_id) where lead_id is not null;
create index if not exists phone_activity_summary_due_idx on phone_activity (summary_due_at) where summary_due_at is not null;
create trigger phone_activity_updated before update on phone_activity for each row execute function app.set_updated_at();
comment on table phone_activity is 'Quo (0085): one call or text on the CarmaCars number, with what Quo sent about it (summary, transcript, recordings, voicemail).';

create table if not exists phone_outbox (
  id               uuid primary key default gen_random_uuid(),
  thread_id        uuid not null references phone_threads (id) on delete cascade,
  to_number        text not null,
  body             text not null check (length(body) between 1 and 1600),
  kind             text not null check (kind in ('missed_call', 'booking', 'staff')),
  sms_kind         text,
  notification_id  uuid,
  booking_id       uuid references bookings (id) on delete set null,
  renter_id        uuid references renters (id) on delete set null,
  status           text not null default 'queued' check (status in ('queued', 'sending', 'sent', 'failed', 'skipped')),
  status_reason    text,
  attempts         integer not null default 0,
  send_after       timestamptz not null default now(),
  locked_at        timestamptz,
  sent_at          timestamptz,
  quo_message_id   text,
  last_error       text,
  sent_by          uuid references users (id) on delete set null,
  dedupe_key       text unique,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists phone_outbox_due_idx on phone_outbox (send_after) where status = 'queued';
create trigger phone_outbox_updated before update on phone_outbox for each row execute function app.set_updated_at();
comment on table phone_outbox is 'Quo (0085): texts to send from the CarmaCars number: the missed-call text, booking texts and staff replies.';

create table if not exists phone_webhook_log (
  id          text primary key,
  type        text not null,
  received_at timestamptz not null default now(),
  result      text
);
create index if not exists phone_webhook_log_at_idx on phone_webhook_log (received_at);
comment on table phone_webhook_log is 'Quo (0085): the webhook deliveries seen, so a delivery Quo retries is applied once. Kept 3 days.';

alter table renters add column if not exists sms_opt_out_at timestamptz;
comment on column renters.sms_opt_out_at is 'Since 0085: the renter asked for no texts (STOP to our number, or staff). Booking texts are not sent.';

alter table leads drop constraint if exists leads_kind_check;
alter table leads add constraint leads_kind_check check (kind in ('owner_program', 'contact', 'insurer', 'launch_notice', 'other', 'chat', 'sample_car', 'phone'));

do $$
declare t text;
begin
  foreach t in array array['quo_config', 'phone_threads', 'phone_activity', 'phone_outbox', 'phone_webhook_log'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists admin_all on %I', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('revoke all on %I from anon, authenticated', t);
  end loop;
end $$;

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description) values
  ('phone_missed_call', 'cs', 'Missed call: call back', 'high', 'opening_minutes', 15, 'A call to the CarmaCars number was missed: call back or reply to their text')
on conflict (task_type) do update set queue = excluded.queue, title = excluded.title, priority = excluded.priority,
  due_kind = excluded.due_kind, due_amount = excluded.due_amount, description = excluded.description;

-- ================================================================ 3. numbers and matching
-- "+16475551234" from what a person typed; null when it is not a phone number.
create or replace function app.phone_e164(p text) returns text
language sql immutable as $$
  select case
    when d ~ '^[2-9][0-9]{9}$' then '+1' || d
    when d ~ '^1[2-9][0-9]{9}$' then '+' || d
    when btrim(coalesce(p, '')) like '+%' and length(d) between 8 and 15 then '+' || d
  end
  from (select regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') as d) x
$$;

-- The CarmaCars number: Site settings, phone (the Quo line).
create or replace function app.phone_our_number() returns text
language sql stable security definer set search_path = public, app as $$
  select app.phone_e164((select phone from site_settings limit 1))
$$;

-- The renter's booking a call is most likely about: on rent, then the next one coming, then the latest.
create or replace function app.phone_current_booking(p_renter uuid) returns uuid
language sql stable security definer set search_path = public, app as $$
  select b.id from bookings b
   where b.renter_id = p_renter and b.status not in ('tentative', 'expired')
   order by case when b.status = 'on_rent' then 0
                 when b.status in ('confirmed', 'pending_payment', 'offered', 'requested') and b.return_at > now() then 1
                 else 2 end,
            case when b.status in ('confirmed', 'pending_payment', 'offered', 'requested') and b.return_at > now() then extract(epoch from b.pickup_at) else -extract(epoch from b.pickup_at) end
   limit 1
$$;

-- Who a number is: staff first, then a renter (or one of their drivers), an owner (or partner), then a lead (a lead, a
-- discount game claim, a chat that gave this phone). The newest record wins within each kind.
create or replace function app.phone_match(p_number text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  n text := app.phone_e164(p_number);
  v_staff uuid; v_renter uuid; v_owner uuid; v_lead uuid; v_claim uuid; v_chat uuid; v_visitor uuid;
  v_name text; v_kind text := 'unknown';
begin
  if n is null then return jsonb_build_object('kind', 'unknown'); end if;
  select u.id, u.full_name into v_staff, v_name from users u
   where app.phone_e164(u.phone) = n and u.status = 'active'
     and exists (select 1 from user_roles r where r.user_id = u.id and r.role in ('admin', 'va', 'field'))
   order by u.created_at desc limit 1;
  if v_staff is not null then v_kind := 'staff'; end if;
  select r.id, coalesce(r.legal_name, v_name) into v_renter, v_name from renters r
   where v_staff is null and (app.phone_e164(r.mobile) = n
      or exists (select 1 from drivers d where d.renter_id = r.id and d.is_account_holder and app.phone_e164(d.mobile) = n))
   order by r.created_at desc limit 1;
  if v_staff is null and v_renter is not null then v_kind := 'renter'; end if;
  if v_kind = 'unknown' then
    select o.id, coalesce(o.corporation_name, o.legal_name) into v_owner, v_name from owners o
     where app.phone_e164(o.phone) = n or exists (select 1 from partners p where p.owner_id = o.id and app.phone_e164(p.phone) = n)
     order by o.created_at desc limit 1;
    if v_owner is not null then v_kind := 'owner'; end if;
  end if;
  -- the lead side is looked up for everyone (a renter who also played a game keeps the link to their visit)
  select g.id, g.lead_id, coalesce(v_name, g.first_name), g.visitor_id into v_claim, v_lead, v_name, v_visitor from game_claims g
   where app.phone_e164(g.phone) = n order by g.created_at desc limit 1;
  select c.id, coalesce(v_lead, c.lead_id), coalesce(v_name, nullif(c.name, '')), coalesce(v_visitor, c.visitor_id) into v_chat, v_lead, v_name, v_visitor from chat_conversations c
   where app.phone_e164(c.phone) = n order by c.created_at desc limit 1;
  if v_lead is null then
    select l.id, coalesce(v_name, l.name) into v_lead, v_name from leads l where app.phone_e164(l.phone) = n order by l.created_at desc limit 1;
  end if;
  if v_kind = 'unknown' and (v_lead is not null or v_claim is not null or v_chat is not null) then v_kind := 'lead'; end if;
  if v_visitor is null and v_renter is not null then
    select s.visitor_id into v_visitor from visitor_sessions s where s.renter_id = v_renter order by s.last_seen_at desc limit 1;
  end if;
  return jsonb_build_object('kind', v_kind, 'name', v_name, 'staff_user_id', v_staff, 'renter_id', v_renter, 'owner_id', v_owner, 'lead_id', v_lead,
    'game_claim_id', v_claim, 'chat_id', v_chat, 'visitor_id', v_visitor,
    'booking_id', case when v_renter is not null then app.phone_current_booking(v_renter) end);
end $$;

-- The thread of a number, created when new; the automatic match refreshed unless staff linked it by hand.
create or replace function app.phone_thread_for(p_number text) returns phone_threads
language plpgsql security definer set search_path = public, app as $$
declare
  n text := app.phone_e164(p_number);
  t phone_threads;
  m jsonb;
begin
  if n is null then raise exception 'Not a phone number: %', coalesce(p_number, '') using errcode = '22023'; end if;
  insert into phone_threads (number) values (n) on conflict (number) do nothing;
  select * into t from phone_threads where number = n for update;
  if not t.manual then
    m := app.phone_match(n);
    update phone_threads set match_kind = m ->> 'kind', name = coalesce(m ->> 'name', name),
           staff_user_id = (m ->> 'staff_user_id')::uuid, renter_id = (m ->> 'renter_id')::uuid, owner_id = (m ->> 'owner_id')::uuid,
           lead_id = (m ->> 'lead_id')::uuid, game_claim_id = (m ->> 'game_claim_id')::uuid, chat_id = (m ->> 'chat_id')::uuid,
           visitor_id = case when (app.settings()).phone_link_visitors then (m ->> 'visitor_id')::uuid end,
           booking_id = (m ->> 'booking_id')::uuid
     where id = t.id returning * into t;
  elsif t.renter_id is not null then
    update phone_threads set booking_id = app.phone_current_booking(t.renter_id) where id = t.id returning * into t;
  end if;
  -- a visitor who gave this phone is shown by name on Live visitors
  if t.visitor_id is not null and t.name is not null then
    update visitor_sessions set known_name = t.name where visitor_id = t.visitor_id and known_name is null and last_seen_at > now() - interval '30 days';
  end if;
  return t;
end $$;

-- ================================================================ 4. templates
-- {first_name}, {booking}, {car}, {pickup}, {return}, {amount}, {link} filled from p; a placeholder without a value is
-- dropped with the space before it.
create or replace function app.phone_render(p_tpl text, p jsonb) returns text
language plpgsql immutable as $$
declare
  t text := coalesce(p_tpl, '');
  k text;
begin
  foreach k in array array['first_name', 'booking', 'car', 'pickup', 'return', 'amount', 'link'] loop
    if nullif(btrim(coalesce(p ->> k, '')), '') is not null then
      t := replace(t, '{' || k || '}', btrim(p ->> k));
    else
      t := regexp_replace(t, '\s?\{' || k || '\}', '', 'g');
    end if;
  end loop;
  t := regexp_replace(t, '\s+', ' ', 'g');
  t := regexp_replace(t, '\s+([,.!?:)])', '\1', 'g');
  t := replace(replace(t, chr(8212), ','), chr(8211), '-');
  return left(btrim(t), 1600);
end $$;

create or replace function app.phone_when(p timestamptz) returns text
language sql immutable as $$
  select case when p is null then null else
    to_char(p at time zone 'America/Toronto', 'Dy Mon FMDD') || ' at ' || lower(to_char(p at time zone 'America/Toronto', 'FMHH12:MI AM')) end
$$;

-- The values of a booking text: the email's own values where it has them, otherwise the booking's.
create or replace function app.phone_sms_vars(p_booking uuid, p_payload jsonb default '{}'::jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'first_name', coalesce(nullif(p_payload ->> 'first_name', ''), split_part(btrim(r.legal_name), ' ', 1)),
    'booking', b.booking_number,
    'car', coalesce(nullif(p_payload ->> 'vehicle_name', ''), app.vehicle_name(b.vehicle_id)),
    'pickup', app.phone_when(b.pickup_at),
    'return', app.phone_when(b.return_at),
    'amount', coalesce(nullif(p_payload ->> 'amount', ''), nullif(p_payload ->> 'amount_paid', ''), nullif(p_payload ->> 'total_amount', '')),
    'link', rtrim(coalesce((select s.site_url from site_settings s limit 1), 'https://carmacars.ca'), '/') || '/account/bookings/' || b.booking_number)
  from bookings b left join renters r on r.id = b.renter_id where b.id = p_booking
$$;

-- The booking text for each renter email (null: no text for that email).
create or replace function app.phone_sms_kind(p_code text) returns text
language sql immutable as $$
  select case p_code
    when 'renter_offer_ready' then 'offer_sent'
    when 'renter_booking_confirmed' then 'payment_confirmed'
    when 'renter_payment_receipt' then 'payment_received'
    when 'renter_booking_reminder' then 'pickup_tomorrow'
    when 'renter_return_reminder' then 'return_reminder'
    when 'renter_recovery_pay' then 'payment_link'
  end
$$;

-- When a text may go: now, or the end of the site check's quiet hours.
create or replace function app.phone_quiet_end(p_now timestamptz default now()) returns timestamptz
language sql stable security definer set search_path = public, app as $$
  select case when not app.uptime_quiet(p_now) then p_now
    else app.local_midnight(app.local_date(p_now) + case when app.local_hour(p_now) >= s.uptime_quiet_until_hour then 1 else 0 end)
         + make_interval(hours => s.uptime_quiet_until_hour) end
    from (select (app.settings(app.local_date(p_now))).*) s
$$;

-- ================================================================ 5. sending
-- A text to a number: queued (or ready to send now), or skipped with the reason when the number opted out.
create or replace function app.phone_outbox_put(p_number text, p_body text, p_kind text, p_booking uuid default null, p_renter uuid default null,
  p_sms_kind text default null, p_notification uuid default null, p_dedupe text default null, p_send_after timestamptz default now(),
  p_status text default 'queued', p_by uuid default null) returns phone_outbox
language plpgsql security definer set search_path = public, app as $$
declare
  t phone_threads := app.phone_thread_for(p_number);
  o phone_outbox;
  v_skip text;
begin
  if p_dedupe is not null then
    select * into o from phone_outbox where dedupe_key = p_dedupe;
    if o.id is not null then return o; end if;
  end if;
  if t.opted_out_at is not null then v_skip := 'The number opted out of texts';
  elsif p_kind = 'booking' and p_renter is not null and exists (select 1 from renters r where r.id = p_renter and r.sms_opt_out_at is not null) then v_skip := 'The renter asked for no texts';
  elsif not (app.settings()).phone_enabled then v_skip := 'Phone and texts are off in Program settings';
  end if;
  insert into phone_outbox (thread_id, to_number, body, kind, sms_kind, notification_id, booking_id, renter_id, status, status_reason, send_after, sent_by, dedupe_key,
                            locked_at)
  values (t.id, t.number, left(p_body, 1600), p_kind, p_sms_kind, p_notification, p_booking, p_renter, case when v_skip is null then p_status else 'skipped' end, v_skip,
          coalesce(p_send_after, now()), p_by, p_dedupe, case when v_skip is null and p_status = 'sending' then now() end)
  returning * into o;
  return o;
end $$;

-- A booking email to a renter queues its text (notification_outbox trigger). Transactional emails only; a marketing
-- email never makes a text.
create or replace function app.phone_sms_from_email() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  ps jsonb := to_jsonb(app.settings());
  v_kind text := app.phone_sms_kind(new.code);
  r renters;
  v_number text;
  v_body text;
  v_first boolean;
begin
  if v_kind is null or new.booking_id is null or new.status = 'skipped' or new.category <> 'transactional' then return new; end if;
  if not coalesce((ps ->> 'phone_enabled')::boolean, false) or not coalesce((ps ->> 'phone_sms_booking')::boolean, false)
     or not coalesce((ps ->> ('phone_sms_' || v_kind))::boolean, false) then return new; end if;
  select x.* into r from renters x join bookings b on b.renter_id = x.id where b.id = new.booking_id;
  v_number := app.phone_e164(r.mobile);
  if v_number is null then return new; end if;
  v_body := app.phone_render(ps ->> ('phone_sms_' || v_kind || '_text'), app.phone_sms_vars(new.booking_id, new.payload));
  select not exists (select 1 from phone_outbox o where o.to_number = v_number and o.kind = 'booking' and o.status in ('queued', 'sending', 'sent')) into v_first;
  if v_first and coalesce((ps ->> 'phone_sms_stop_line')::boolean, false) then v_body := v_body || ' Reply STOP to opt out.'; end if;
  perform app.phone_outbox_put(v_number, v_body, 'booking', new.booking_id, r.id, v_kind, new.id, 'sms:' || new.dedupe_key,
    case when coalesce((ps ->> 'phone_sms_quiet_hours')::boolean, false) then greatest(new.send_after, app.phone_quiet_end(now())) else new.send_after end);
  return new;
end $$;
drop trigger if exists notification_outbox_phone_sms on notification_outbox;
create trigger notification_outbox_phone_sms after insert on notification_outbox for each row execute function app.phone_sms_from_email();

-- ================================================================ 6. the missed call
-- The person on duty in a function: someone holding it who had Live chat, Live visitors or Texts open within the
-- shift minutes (the most recent). Null when nobody is.
create or replace function app.phone_on_duty(p_fn text) returns uuid
language sql stable security definer set search_path = public, app as $$
  select p.user_id from chat_staff_prefs p
    join staff_profiles sp on sp.user_id = p.user_id and sp.staff_type = 'va' and sp.is_active
    join users u on u.id = p.user_id and u.status = 'active'
   where p.last_seen_at > now() - make_interval(mins => (app.settings()).chat_shift_minutes)
     and (sp.va_function::text = p_fn or p_fn = any (array(select x::text from unnest(sp.cover_functions) x)))
   order by p.last_seen_at desc limit 1
$$;

create or replace function app.phone_fn_held(p_fn text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from staff_profiles sp join users u on u.id = sp.user_id and u.status = 'active'
                   join user_roles r on r.user_id = sp.user_id and r.role = 'va'
                  where sp.staff_type = 'va' and sp.is_active
                    and (sp.va_function::text = p_fn or p_fn = any (array(select x::text from unnest(sp.cover_functions) x))))
$$;

-- A missed call: once per call. The text back (once per number in the hours set) and the task. Returns the text to
-- send now (or null).
create or replace function app.phone_missed(p_activity uuid) returns phone_outbox
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  a phone_activity;
  t phone_threads;
  o phone_outbox;
  v_queue text := ps.phone_missed_call_queue;
  v_assignee uuid;
  v_task uuid;
  v_quiet boolean := app.uptime_quiet(now());
begin
  select * into a from phone_activity where id = p_activity for update;
  if a.id is null or a.missed_handled or a.direction <> 'in' then return null; end if;
  update phone_activity set missed = true, missed_handled = true where id = a.id;
  select * into t from phone_threads where id = a.thread_id for update;
  if ps.phone_missed_call_text_enabled and t.opted_out_at is null and t.match_kind <> 'staff'
     and (t.last_missed_text_at is null or t.last_missed_text_at < now() - make_interval(hours => ps.phone_missed_call_text_hours)) then
    o := app.phone_outbox_put(t.number, ps.phone_missed_call_text, 'missed_call', t.booking_id, t.renter_id, null, null, 'missed:' || a.id, now(), 'sending');
    if o.status = 'sending' then update phone_threads set last_missed_text_at = now() where id = t.id; end if;
  end if;
  if ps.phone_missed_call_task and t.match_kind <> 'staff' then
    if v_queue <> 'admin' then
      if not app.phone_fn_held(v_queue) then v_queue := 'admin';
      else v_assignee := app.phone_on_duty(v_queue); end if;
    end if;
    v_task := app.raise_task(p_type => 'phone_missed_call', p_queue => v_queue,
      p_title => left(format('Missed call from %s', coalesce(t.name, app.phone_display(t.number))), 200),
      p_detail => format('%s called %s and nobody answered.%s Call back, or reply in Live chat, Texts and calls.', app.phone_display(t.number),
                         app.phone_when(a.started_at), case when o.status = 'sending' then ' We texted them back automatically.' else '' end),
      p_booking => t.booking_id, p_renter => t.renter_id, p_owner => t.owner_id, p_related_table => 'phone_threads', p_related_id => t.id,
      p_due_at => case when v_quiet then app.phone_quiet_end(now()) end, p_dedupe => 'phone_missed:' || t.id);
    if v_assignee is not null then update tasks set assigned_to = v_assignee where id = v_task and assigned_to is null; end if;
  end if;
  return case when o.status = 'sending' then o end;
end $$;

-- ================================================================ 7. the webhook (the Worker parsed and verified it)
-- p: {event_id, type, quo_id, call_id, direction, from, to, their_number, phone_number_id, conversation_id, user_id, text,
--     status, error_code, media, at, answered_at, completed_at, duration, missed, recordings, summary, next_steps,
--     transcript, voicemail_text, voicemail_url}. Answers {ok, activity_id, send: [{id, to, body}], ignored, duplicate}.
create or replace function app.server_phone_event(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  v_type text := coalesce(p ->> 'type', '');
  v_ours text := app.phone_our_number();
  v_cfg quo_config;
  v_their text;
  v_dir text := coalesce(p ->> 'direction', 'in');
  t phone_threads;
  a phone_activity;
  o phone_outbox;
  v_send jsonb := '[]'::jsonb;
  v_is_call boolean := v_type like 'call.%';
  v_quo text := coalesce(nullif(p ->> 'call_id', ''), nullif(p ->> 'quo_id', ''));
  v_body text := p ->> 'text';
  v_new boolean := false;
begin
  if nullif(p ->> 'event_id', '') is not null then
    insert into phone_webhook_log (id, type) values (p ->> 'event_id', v_type) on conflict (id) do nothing;
    if not found then return jsonb_build_object('ok', true, 'duplicate', true); end if;
  end if;
  if not ps.phone_enabled then return jsonb_build_object('ok', true, 'ignored', 'off'); end if;
  if (v_is_call and not ps.phone_record_calls) or (v_type like 'message.%' and not ps.phone_record_texts) then
    return jsonb_build_object('ok', true, 'ignored', 'not recorded');
  end if;
  select * into v_cfg from quo_config;
  if v_cfg.phone_number_id is not null and nullif(p ->> 'phone_number_id', '') is not null and p ->> 'phone_number_id' <> v_cfg.phone_number_id then
    return jsonb_build_object('ok', true, 'ignored', 'another number');
  end if;
  v_their := app.phone_e164(p ->> 'their_number');
  if v_their is null and v_quo is not null then
    select x.number into v_their from phone_activity y join phone_threads x on x.id = y.thread_id where y.quo_id = v_quo;
  end if;
  if v_their is null or v_their = v_ours then return jsonb_build_object('ok', true, 'ignored', 'no outside number'); end if;
  t := app.phone_thread_for(v_their);
  if v_quo is not null then select * into a from phone_activity where quo_id = v_quo for update; end if;
  if a.id is null then
    insert into phone_activity (thread_id, kind, direction, quo_id, quo_conversation_id, quo_user_id, status, body, started_at,
                                renter_id, owner_id, lead_id, staff_user_id, booking_id)
    values (t.id, case when v_is_call then 'call' else 'text' end, v_dir, v_quo, p ->> 'conversation_id', p ->> 'user_id', p ->> 'status',
            case when v_is_call then null else left(v_body, 4000) end, coalesce((p ->> 'at')::timestamptz, now()),
            t.renter_id, t.owner_id, t.lead_id, t.staff_user_id, t.booking_id)
    returning * into a;
    v_new := true;
  end if;

  if v_type like 'message.%' then
    update phone_activity set status = coalesce(p ->> 'status', status), error_code = coalesce(p ->> 'error_code', error_code),
           body = coalesce(body, left(v_body, 4000)), media = coalesce(p -> 'media', media)
     where id = a.id returning * into a;
    if v_type = 'message.received' and v_new then
      update phone_threads set unread = unread + 1, last_at = a.started_at, last_preview = left(coalesce(v_body, '(picture)'), 140), last_direction = 'in',
             quo_conversation_id = coalesce(p ->> 'conversation_id', quo_conversation_id)
       where id = t.id;
      -- STOP and START (Quo and the carriers also stop texts on their side)
      if btrim(upper(coalesce(v_body, ''))) ~ '^(STOP|STOPALL|UNSUBSCRIBE|CANCEL|END|QUIT|ARRET)$' then
        update phone_threads set opted_out_at = now(), opt_out_source = 'stop' where id = t.id;
        update renters set sms_opt_out_at = coalesce(sms_opt_out_at, now()) where id = t.renter_id;
        update phone_outbox set status = 'skipped', status_reason = 'The number opted out of texts' where thread_id = t.id and status = 'queued';
      elsif btrim(upper(coalesce(v_body, ''))) ~ '^(START|UNSTOP|YES)$' and t.opted_out_at is not null then
        update phone_threads set opted_out_at = null, opt_out_source = null where id = t.id;
        update renters set sms_opt_out_at = null where id = t.renter_id;
      end if;
    elsif v_type in ('message.failed', 'message.undelivered') and coalesce(p ->> 'error_code', '') in ('21610', '30004', '30005', '30006') then
      -- the carrier says the number blocked us, does not exist or is a landline: no more texts to it
      update phone_threads set opted_out_at = coalesce(opted_out_at, now()), opt_out_source = coalesce(opt_out_source, 'carrier') where id = t.id;
    elsif v_new then
      update phone_threads set last_at = a.started_at, last_preview = left(coalesce(v_body, ''), 140), last_direction = 'out' where id = t.id;
    end if;
  else
    update phone_activity set
      status = coalesce(p ->> 'status', status),
      answered_at = coalesce((p ->> 'answered_at')::timestamptz, answered_at),
      ended_at = coalesce((p ->> 'completed_at')::timestamptz, ended_at),
      duration_seconds = coalesce((p ->> 'duration')::integer, duration_seconds),
      recordings = case when jsonb_typeof(p -> 'recordings') = 'array' and jsonb_array_length(p -> 'recordings') > 0 then p -> 'recordings' else recordings end,
      quo_summary = case when jsonb_typeof(p -> 'summary') = 'array' and jsonb_array_length(p -> 'summary') > 0 then p -> 'summary' else quo_summary end,
      next_steps = case when jsonb_typeof(p -> 'next_steps') = 'array' and jsonb_array_length(p -> 'next_steps') > 0 then p -> 'next_steps' else next_steps end,
      transcript = case when jsonb_typeof(p -> 'transcript') = 'array' and jsonb_array_length(p -> 'transcript') > 0 then p -> 'transcript' else transcript end,
      voicemail_text = coalesce(nullif(p ->> 'voicemail_text', ''), voicemail_text),
      voicemail_url = coalesce(nullif(p ->> 'voicemail_url', ''), voicemail_url),
      direction = case when v_new then direction else coalesce(nullif(p ->> 'direction', ''), direction) end
     where id = a.id returning * into a;
    if v_new or v_type in ('call.completed', 'call.missed') then
      update phone_threads set last_at = greatest(coalesce(last_at, a.started_at), a.started_at),
             last_preview = case when a.direction = 'in' then 'Call' else 'Call made' end, last_direction = a.direction where id = t.id;
    end if;
    -- a summary from Quo replaces the wait for our own; a transcript without one gets ours a few minutes later
    if a.quo_summary is not null then
      update phone_activity set summary_due_at = null where id = a.id;
    elsif v_type = 'call.transcript.completed' and a.transcript is not null and ps.phone_ai_summaries and a.ai_summary is null then
      update phone_activity set summary_due_at = now() + interval '5 minutes' where id = a.id;
    end if;
    if a.direction = 'in' and (v_type = 'call.missed' or coalesce((p ->> 'missed')::boolean, false)) then
      o := app.phone_missed(a.id);
      if o.id is not null then v_send := jsonb_build_array(jsonb_build_object('id', o.id, 'to', o.to_number, 'body', o.body)); end if;
    end if;
  end if;
  update phone_webhook_log set result = 'ok' where id = p ->> 'event_id';
  return jsonb_build_object('ok', true, 'activity_id', a.id, 'thread_id', t.id, 'send', v_send);
end $$;

-- The result of a send through Quo: the outbox row, and the text on the thread (the delivered webhook then finds it).
create or replace function app.server_phone_sent(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o phone_outbox;
  t phone_threads;
  v_ok boolean := coalesce((p ->> 'ok')::boolean, false);
begin
  select * into o from phone_outbox where id = (p ->> 'id')::uuid for update;
  if o.id is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if o.status = 'sent' then return jsonb_build_object('ok', true, 'already', true); end if;
  if v_ok then
    update phone_outbox set status = 'sent', sent_at = now(), quo_message_id = nullif(p ->> 'quo_id', ''), locked_at = null, attempts = attempts + 1, last_error = null
     where id = o.id returning * into o;
    select * into t from phone_threads where id = o.thread_id;
    insert into phone_activity (thread_id, kind, direction, quo_id, status, body, started_at, renter_id, owner_id, lead_id, staff_user_id, booking_id, sent_by, outbox_id, sms_kind)
    values (t.id, 'text', 'out', o.quo_message_id, 'sent', o.body, now(), coalesce(o.renter_id, t.renter_id), t.owner_id, t.lead_id, t.staff_user_id,
            coalesce(o.booking_id, t.booking_id), o.sent_by, o.id, coalesce(o.sms_kind, o.kind))
    on conflict (quo_id) do update set outbox_id = excluded.outbox_id, sent_by = excluded.sent_by, sms_kind = excluded.sms_kind;
    update phone_threads set last_at = now(), last_preview = left(o.body, 140), last_direction = 'out',
           unread = case when o.kind = 'staff' then 0 else unread end, staff_read_at = case when o.kind = 'staff' then now() else staff_read_at end
     where id = t.id;
  else
    update phone_outbox set attempts = attempts + 1, locked_at = null, last_error = left(p ->> 'error', 500),
           status = case when o.kind = 'staff' or o.attempts + 1 >= 3 or coalesce((p ->> 'permanent')::boolean, false) then 'failed' else 'queued' end,
           send_after = now() + make_interval(mins => 5 * (o.attempts + 1))
     where id = o.id returning * into o;
  end if;
  return jsonb_build_object('ok', true, 'status', o.status);
end $$;

-- The five-minute job: texts that are due (claimed for sending) and calls whose AI summary is due.
create or replace function app.server_phone_due(p_limit integer default 20) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_texts jsonb;
  v_sums jsonb;
begin
  -- a send that never reported back is tried again after 10 minutes
  update phone_outbox set status = 'queued', locked_at = null where status = 'sending' and kind <> 'staff' and locked_at < now() - interval '10 minutes';
  with due as (
    select id from phone_outbox where status = 'queued' and send_after <= now() order by send_after limit p_limit for update skip locked)
  update phone_outbox o set status = 'sending', locked_at = now() from due where o.id = due.id;
  select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'to', o.to_number, 'body', o.body)), '[]'::jsonb) into v_texts
    from phone_outbox o where o.status = 'sending' and o.locked_at > now() - interval '5 seconds';
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'transcript', a.transcript, 'direction', a.direction, 'duration', a.duration_seconds)), '[]'::jsonb) into v_sums
    from (select * from phone_activity where summary_due_at <= now() and ai_summary is null and quo_summary is null order by summary_due_at limit 5) a;
  return jsonb_build_object('texts', v_texts, 'summaries', v_sums, 'ai', app.phone_ai_budget(), 'from', app.phone_our_number());
end $$;

-- ================================================================ 8. AI: drafts and summaries
create or replace function app.phone_ai_budget() returns jsonb
language sql stable security definer set search_path = public, app as $$
  with day as (select app.local_midnight(app.local_date(now())) as t0),
  u as (select coalesce(sum(c.units) filter (where c.purpose in ('phone_draft', 'phone_summary')), 0) as phone,
               coalesce(sum(c.units), 0) as all_units
          from provider_calls c, day where c.unit = 'neurons' and c.created_at >= day.t0)
  select jsonb_build_object('neurons', u.phone, 'cap', s.phone_ai_daily_neurons, 'all_neurons', u.all_units, 'all_cap', s.chat_ai_total_daily_neurons,
    'drafts', s.phone_ai_drafts, 'summaries', s.phone_ai_summaries, 'model', s.chat_ai_model,
    'ok', u.phone < s.phone_ai_daily_neurons and u.all_units < s.chat_ai_total_daily_neurons)
  from u, (select (app.settings()).*) s
$$;

create or replace function app.server_phone_ai_log(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if coalesce(p ->> 'purpose', '') not in ('phone_draft', 'phone_summary') then raise exception 'Unknown purpose' using errcode = '22023'; end if;
  insert into provider_calls (provider, purpose, ok, error, duration_ms, units, unit)
  values (coalesce(nullif(p ->> 'provider', ''), 'workers-ai'), p ->> 'purpose', coalesce((p ->> 'ok')::boolean, true), left(p ->> 'error', 300),
          nullif(p ->> 'duration_ms', '')::integer, coalesce((p ->> 'neurons')::numeric, 0), 'neurons');
  return app.phone_ai_budget();
end $$;

-- The AI one-liner of a call (never over Quo's own summary). p: {id, summary, ok, neurons, error, duration_ms}
create or replace function app.server_phone_summary(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_line text := left(btrim(regexp_replace(coalesce(p ->> 'summary', ''), '\s+', ' ', 'g')), 200);
begin
  perform app.server_phone_ai_log(jsonb_build_object('purpose', 'phone_summary') || (p - 'summary' - 'id'));
  v_line := replace(replace(v_line, chr(8212), ','), chr(8211), '-');
  update phone_activity set ai_summary = case when quo_summary is null and v_line <> '' and coalesce((p ->> 'ok')::boolean, true) then v_line else ai_summary end,
         summary_due_at = null
   where id = (p ->> 'id')::uuid;
  return jsonb_build_object('ok', true);
end $$;

-- ================================================================ 9. reads and actions for staff
create or replace function app.phone_item(a phone_activity) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', a.id, 'thread_id', a.thread_id, 'kind', a.kind, 'direction', a.direction, 'at', a.started_at, 'status', a.status,
    'body', a.body, 'media', a.media, 'missed', a.missed, 'duration', a.duration_seconds, 'answered_at', a.answered_at,
    'voicemail_text', a.voicemail_text, 'voicemail_url', a.voicemail_url, 'recordings', a.recordings,
    'summary', coalesce(a.quo_summary ->> 0, a.ai_summary), 'summary_lines', a.quo_summary, 'summary_by', case when a.quo_summary is not null then 'quo' when a.ai_summary is not null then 'ai' end,
    'next_steps', a.next_steps, 'transcript', a.transcript, 'sms_kind', a.sms_kind, 'error_code', a.error_code,
    'by', (select u.full_name from users u where u.id = a.sent_by),
    'number', (select app.phone_display(x.number) from phone_threads x where x.id = a.thread_id),
    'booking_number', (select b.booking_number from bookings b where b.id = a.booking_id))
$$;

create or replace function app.phone_thread_row(t phone_threads) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', t.id, 'number', t.number, 'display', app.phone_display(t.number), 'who', coalesce(t.name, app.phone_display(t.number)),
    'name', t.name, 'match_kind', t.match_kind, 'manual', t.manual, 'renter_id', t.renter_id, 'owner_id', t.owner_id, 'lead_id', t.lead_id,
    'staff_user_id', t.staff_user_id, 'booking_id', t.booking_id,
    'booking_number', (select b.booking_number from bookings b where b.id = t.booking_id),
    'last_at', t.last_at, 'last', t.last_preview, 'last_direction', t.last_direction, 'unread', t.unread, 'opted_out', t.opted_out_at is not null,
    'opt_out_source', t.opt_out_source, 'visitor_id', t.visitor_id,
    'missed', (select count(*) from phone_activity a where a.thread_id = t.id and a.missed and a.started_at > coalesce(t.staff_read_at, '-infinity'::timestamptz)))
$$;

create or replace function app.phone_inbox(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_view text := coalesce(nullif(p ->> 'view', ''), 'all');
  v_q text := nullif(btrim(coalesce(p ->> 'q', '')), '');
begin
  perform app.assert_live_staff(p_by);
  return jsonb_build_object('at', now(), 'enabled', (app.settings()).phone_enabled, 'number', app.phone_display(app.phone_our_number()),
    'threads', coalesce((select jsonb_agg(app.phone_thread_row(t) order by t.last_at desc nulls last) from (
        select * from phone_threads t
         where t.last_at is not null
           and (v_view = 'all' or (v_view = 'unknown' and t.match_kind = 'unknown') or (v_view = 'unread' and t.unread > 0))
           and (v_q is null or t.number like '%' || regexp_replace(v_q, '[^0-9]', '', 'g') || '%' and regexp_replace(v_q, '[^0-9]', '', 'g') <> '' or t.name ilike '%' || v_q || '%')
         order by t.last_at desc nulls last limit 100) t), '[]'::jsonb),
    'unread', (select coalesce(sum(unread), 0) from phone_threads),
    'unknown', (select count(*) from phone_threads where match_kind = 'unknown' and last_at is not null),
    'ai', app.phone_ai_budget());
end $$;

create or replace function app.phone_thread(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  t phone_threads;
  v_session uuid;
begin
  perform app.assert_live_staff(p_by);
  select * into t from phone_threads where id = (p ->> 'id')::uuid;
  if t.id is null then raise exception 'That conversation is no longer kept' using errcode = 'P0002'; end if;
  if t.visitor_id is not null and (app.settings()).phone_link_visitors then
    select s.id into v_session from visitor_sessions s where s.visitor_id = t.visitor_id order by s.last_seen_at desc limit 1;
  end if;
  return jsonb_build_object('thread', app.phone_thread_row(t),
    'items', coalesce((select jsonb_agg(app.phone_item(a) order by a.started_at) from (select * from phone_activity where thread_id = t.id order by started_at desc limit 200) a), '[]'::jsonb),
    'renter', (select jsonb_build_object('id', r.id, 'name', r.legal_name, 'email', r.email, 'mobile', r.mobile, 'sms_opt_out', r.sms_opt_out_at is not null,
                 'bookings', coalesce((select jsonb_agg(jsonb_build_object('number', b.booking_number, 'status', b.status, 'pickup_at', b.pickup_at) order by b.pickup_at desc)
                                         from (select * from bookings where renter_id = r.id order by pickup_at desc limit 5) b), '[]'::jsonb))
                from renters r where r.id = t.renter_id),
    'owner', (select jsonb_build_object('id', o.id, 'name', coalesce(o.corporation_name, o.legal_name)) from owners o where o.id = t.owner_id),
    'lead', (select jsonb_build_object('id', l.id, 'name', l.name, 'kind', l.kind, 'status', l.status, 'email', l.email) from leads l where l.id = t.lead_id),
    'staff', (select jsonb_build_object('id', u.id, 'name', u.full_name) from users u where u.id = t.staff_user_id),
    'visit', case when v_session is not null then app.live_session(p_by, jsonb_build_object('id', v_session)) end,
    'ai', app.phone_ai_budget());
end $$;

-- The calls and texts of a record: a booking, a renter, an owner, a lead, a staff member or a thread.
create or replace function app.phone_timeline(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_booking uuid := nullif(p ->> 'booking_id', '')::uuid;
  v_renter uuid := nullif(p ->> 'renter_id', '')::uuid;
  v_owner uuid := nullif(p ->> 'owner_id', '')::uuid;
  v_lead uuid := nullif(p ->> 'lead_id', '')::uuid;
  v_staff uuid := nullif(p ->> 'staff_id', '')::uuid;
begin
  perform app.assert_live_staff(p_by);
  return jsonb_build_object('items', coalesce((select jsonb_agg(app.phone_item(a) order by a.started_at desc) from (
      select a.* from phone_activity a join phone_threads t on t.id = a.thread_id
       where (v_booking is not null and (a.booking_id = v_booking
               or (a.booking_id is null and a.renter_id = (select renter_id from bookings where id = v_booking)
                   and a.started_at between (select pickup_at from bookings where id = v_booking) - interval '30 days' and (select return_at from bookings where id = v_booking) + interval '30 days')))
          or (v_renter is not null and (a.renter_id = v_renter or t.renter_id = v_renter))
          or (v_owner is not null and (a.owner_id = v_owner or t.owner_id = v_owner))
          or (v_lead is not null and (a.lead_id = v_lead or t.lead_id = v_lead))
          or (v_staff is not null and (a.staff_user_id = v_staff or t.staff_user_id = v_staff))
       order by a.started_at desc limit 100) a), '[]'::jsonb),
    'threads', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'display', app.phone_display(t.number), 'opted_out', t.opted_out_at is not null)) from phone_threads t
       where (v_renter is not null and t.renter_id = v_renter) or (v_owner is not null and t.owner_id = v_owner)
          or (v_lead is not null and t.lead_id = v_lead) or (v_staff is not null and t.staff_user_id = v_staff)
          or (v_booking is not null and t.renter_id = (select renter_id from bookings where id = v_booking))), '[]'::jsonb));
end $$;

create or replace function app.phone_renter_search(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  q text := nullif(btrim(coalesce(p ->> 'q', '')), '');
begin
  perform app.assert_live_staff(p_by);
  if q is null or length(q) < 2 then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'name', r.legal_name, 'email', r.email, 'mobile', r.mobile)) from (
    select * from renters r where r.legal_name ilike '%' || q || '%' or r.email ilike '%' || q || '%'
       or (regexp_replace(q, '[^0-9]', '', 'g') <> '' and regexp_replace(coalesce(r.mobile, ''), '[^0-9]', '', 'g') like '%' || regexp_replace(q, '[^0-9]', '', 'g') || '%')
     order by r.created_at desc limit 10) r), '[]'::jsonb);
end $$;

-- Staff actions: read, reply (returns the text for the server to send), link, create a lead, opt out.
create or replace function app.phone_staff_do(p_by uuid, p_action text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  t phone_threads;
  o phone_outbox;
  v_lead uuid;
  v_body text;
  v_before jsonb;
begin
  perform app.assert_live_staff(p_by);
  select * into t from phone_threads where id = (p ->> 'id')::uuid for update;
  if t.id is null then raise exception 'That conversation is no longer kept' using errcode = 'P0002'; end if;
  v_before := to_jsonb(t);
  if p_action = 'phone_read' then
    update phone_threads set unread = 0, staff_read_at = now() where id = t.id;
    -- the staff member is on duty while the inbox is open
    insert into chat_staff_prefs (user_id, last_seen_at) values (p_by, now()) on conflict (user_id) do update set last_seen_at = now();
    return jsonb_build_object('ok', true);
  elsif p_action = 'phone_reply' then
    v_body := btrim(coalesce(p ->> 'body', ''));
    if v_body = '' then raise exception 'Write the text first' using errcode = '22023'; end if;
    if length(v_body) > 1600 then raise exception 'A text is at most 1,600 characters' using errcode = '22023'; end if;
    if t.opted_out_at is not null then raise exception 'This number opted out of texts. They can text START to allow them again.' using errcode = '23514'; end if;
    if not (app.settings()).phone_enabled then raise exception 'Phone and texts are off in Program settings' using errcode = '23514'; end if;
    o := app.phone_outbox_put(t.number, v_body, 'staff', t.booking_id, t.renter_id, null, null, null, now(), 'sending', p_by);
    return jsonb_build_object('ok', true, 'send', jsonb_build_object('id', o.id, 'to', o.to_number, 'body', o.body), 'from', app.phone_our_number());
  elsif p_action = 'phone_link' then
    if nullif(p ->> 'renter_id', '') is not null then
      if not exists (select 1 from renters where id = (p ->> 'renter_id')::uuid) then raise exception 'Renter not found' using errcode = 'P0002'; end if;
      update phone_threads set renter_id = (p ->> 'renter_id')::uuid, match_kind = 'renter', manual = true, linked_by = p_by, linked_at = now(),
             name = (select legal_name from renters where id = (p ->> 'renter_id')::uuid),
             booking_id = app.phone_current_booking((p ->> 'renter_id')::uuid)
       where id = t.id returning * into t;
    elsif nullif(p ->> 'owner_id', '') is not null then
      update phone_threads set owner_id = (p ->> 'owner_id')::uuid, match_kind = 'owner', manual = true, linked_by = p_by, linked_at = now() where id = t.id returning * into t;
    elsif coalesce((p ->> 'automatic')::boolean, false) then
      update phone_threads set manual = false, linked_by = p_by, linked_at = now() where id = t.id;
      t := app.phone_thread_for(t.number);
    else
      raise exception 'Choose a renter or an owner' using errcode = '22023';
    end if;
    -- the conversation so far follows the link
    update phone_activity set renter_id = t.renter_id, owner_id = t.owner_id, lead_id = t.lead_id, booking_id = coalesce(booking_id, t.booking_id) where thread_id = t.id;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
    values (p_by, 'phone_link', 'phone_threads', t.id::text, v_before - 'last_preview', to_jsonb(t) - 'last_preview');
    return jsonb_build_object('ok', true, 'thread', app.phone_thread_row(t));
  elsif p_action = 'phone_create_lead' then
    insert into leads (kind, name, phone, message, source, assigned_to)
    values ('phone', nullif(btrim(coalesce(p ->> 'name', t.name, '')), ''), t.number, nullif(btrim(coalesce(p ->> 'note', '')), ''), 'phone', p_by)
    returning id into v_lead;
    update phone_threads set lead_id = v_lead, match_kind = case when match_kind = 'unknown' then 'lead' else match_kind end,
           name = coalesce(nullif(btrim(coalesce(p ->> 'name', '')), ''), name), manual = true, linked_by = p_by, linked_at = now()
     where id = t.id returning * into t;
    update phone_activity set lead_id = v_lead where thread_id = t.id;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
    values (p_by, 'phone_create_lead', 'phone_threads', t.id::text, v_before - 'last_preview', to_jsonb(t) - 'last_preview');
    return jsonb_build_object('ok', true, 'lead_id', v_lead, 'thread', app.phone_thread_row(t));
  elsif p_action = 'phone_opt_out' then
    if coalesce((p ->> 'on')::boolean, true) then
      update phone_threads set opted_out_at = now(), opt_out_source = 'staff' where id = t.id;
      update renters set sms_opt_out_at = coalesce(sms_opt_out_at, now()) where id = t.renter_id;
      update phone_outbox set status = 'skipped', status_reason = 'The number opted out of texts' where thread_id = t.id and status = 'queued';
    else
      update phone_threads set opted_out_at = null, opt_out_source = null where id = t.id;
      update renters set sms_opt_out_at = null where id = t.renter_id;
    end if;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
    values (p_by, 'phone_opt_out', 'phone_threads', t.id::text, jsonb_build_object('opted_out', v_before ->> 'opted_out_at' is not null),
            jsonb_build_object('opted_out', coalesce((p ->> 'on')::boolean, true)));
    return jsonb_build_object('ok', true);
  elsif p_action = 'phone_draft' then
    -- what the AI drafts from (the server calls the model; a draft is only put in the reply box)
    if not (app.settings()).phone_ai_drafts then raise exception 'AI drafts are off in Program settings' using errcode = '23514'; end if;
    return jsonb_build_object('ok', true, 'ai', app.phone_ai_budget(), 'who', coalesce(t.name, 'the customer'),
      'booking', (select jsonb_build_object('number', b.booking_number, 'status', b.status, 'car', app.vehicle_name(b.vehicle_id),
                    'pickup', app.phone_when(b.pickup_at), 'return', app.phone_when(b.return_at)) from bookings b where b.id = t.booking_id),
      'site', (select jsonb_build_object('brand', s ->> 'brand_name', 'phone', s ->> 'phone_display', 'email', s ->> 'email', 'hours', s ->> 'opening_hours_text', 'url', s ->> 'site_url')
                 from (select public.site_settings_public() as s) x),
      'messages', coalesce((select jsonb_agg(jsonb_build_object('from', case when a.direction = 'in' then 'customer' else 'carmacars' end,
                    'kind', a.kind, 'text', case when a.kind = 'call' then case when a.missed then 'Missed call' else concat_ws(': ', 'Call', coalesce(a.quo_summary ->> 0, a.ai_summary)) end else a.body end,
                    'at', app.phone_when(a.started_at)) order by a.started_at)
                    from (select * from phone_activity where thread_id = t.id order by started_at desc limit 12) a), '[]'::jsonb));
  end if;
  raise exception 'Unknown action %', p_action using errcode = '22023';
end $$;

-- ================================================================ 10. retention
create or replace function app.job_phone_housekeeping(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_months integer := (app.settings()).phone_keep_months;
  v_a integer; v_t integer; v_l integer; v_o integer;
begin
  delete from phone_webhook_log where received_at < p_now - interval '3 days';
  get diagnostics v_l = row_count;
  -- kept with the rental records: a call or text linked to a renter, an owner or a booking
  delete from phone_activity a using phone_threads t
   where t.id = a.thread_id and a.started_at < p_now - make_interval(months => v_months)
     and a.renter_id is null and a.owner_id is null and a.booking_id is null and t.renter_id is null and t.owner_id is null;
  get diagnostics v_a = row_count;
  delete from phone_outbox where created_at < p_now - make_interval(months => v_months) and booking_id is null and renter_id is null;
  get diagnostics v_o = row_count;
  delete from phone_threads t where t.renter_id is null and t.owner_id is null and coalesce(t.last_at, t.created_at) < p_now - make_interval(months => v_months)
     and not exists (select 1 from phone_activity a where a.thread_id = t.id) and not exists (select 1 from phone_outbox o where o.thread_id = t.id);
  get diagnostics v_t = row_count;
  return format('activity %s, threads %s, outbox %s, webhook log %s', v_a, v_t, v_o, v_l);
end $$;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-phone-housekeeping', '41 8 * * *', 'select app.job_phone_housekeeping()');
  end if;
end $$;

-- ================================================================ 11. the cron gate: texts and summaries due
alter function app.server_jobs_due() rename to server_jobs_due_pre0085;
create or replace function app.server_jobs_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  return app.server_jobs_due_pre0085() || jsonb_build_object('phone',
    exists (select 1 from phone_outbox where status = 'queued' and send_after <= now())
    or exists (select 1 from phone_outbox where status = 'sending' and kind <> 'staff' and locked_at < now() - interval '10 minutes')
    or exists (select 1 from phone_activity where summary_due_at <= now()));
end $$;
revoke all on function app.server_jobs_due(), app.server_jobs_due_pre0085() from public, anon, authenticated;
grant execute on function app.server_jobs_due(), app.server_jobs_due_pre0085() to service_role;

-- ================================================================ 12. privacy policy (the live legal.privacy block, where it still has our text)
update site_content_blocks
   set body = replace(body, '| Messages: emails, texts and portal messages with us | To serve you and keep a record |',
     '| Messages: emails, texts and portal messages with us | To serve you and keep a record |
| Calls and texts with our phone number: your number, the time and length of each call, its recording, transcript and summary, and the content of texts | To answer you, keep a record with your booking and call you back |')
 where block_key = 'legal.privacy' and body like '%| Messages: emails, texts and portal messages with us | To serve you and keep a record |%' and body not like '%Calls and texts with our phone number%';
update site_content_blocks
   set body = replace(body, '| Live chat conversations | With your rental records if you are a customer; otherwise 12 months |',
     '| Live chat conversations | With your rental records if you are a customer; otherwise 12 months |
| Calls and texts with our phone number, with their recordings, transcripts and summaries | With your rental records if you are a customer; otherwise 12 months |')
 where block_key = 'legal.privacy' and body like '%| Live chat conversations | With your rental records if you are a customer; otherwise 12 months |%' and body not like '%Calls and texts with our phone number, with%';
update site_content_blocks
   set body = replace(body, 'If you give an email address in the chat, we can email you a copy of the conversation.',
     'If you give an email address in the chat, we can email you a copy of the conversation.

Calls and texts to and from our phone number go through our business phone provider and are recorded: for a call, your number, the time, its length, the recording, a transcript and a short summary written by our provider or an automated tool; for a text, its content. We match your number to your booking or account so our staff see the conversation with your rental, and, if you gave the same number in live chat or a discount game, with your visit to the Site. If we miss your call, we text you once from the same number. Texts about your booking are not marketing; reply STOP to stop them. Calls and texts are kept with your rental records if you are a customer, and otherwise for 12 months.')
 where block_key = 'legal.privacy' and body like '%If you give an email address in the chat, we can email you a copy of the conversation.%' and body not like '%Calls and texts to and from our phone number%';

-- ================================================================ 13. the doors and privileges
create or replace function app.ops85(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  case p_name
  when 'phone_inbox' then return app.phone_inbox(p_user, p);
  when 'phone_thread' then return app.phone_thread(p_user, p);
  when 'phone_timeline' then return app.phone_timeline(p_user, p);
  when 'phone_renter_search' then return app.phone_renter_search(p_user, p);
  when 'phone_read', 'phone_reply', 'phone_link', 'phone_create_lead', 'phone_opt_out', 'phone_draft' then return app.phone_staff_do(p_user, p_name, p);
  else raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0085;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if (p_call in ('va_read', 'admin_read', 'ops_read') and p_name in ('phone_inbox', 'phone_thread', 'phone_timeline', 'phone_renter_search'))
     or (p_call in ('va_do', 'admin_do', 'ops_do') and p_name in ('phone_read', 'phone_reply', 'phone_link', 'phone_create_lead', 'phone_opt_out', 'phone_draft')) then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.ops85(p_user, p_call, p_name, p_ - '_va');
  end if;
  return app.door_pre0085(p_user, p_aal, p_call, p_name, p);
end $$;

create or replace function public.server_phone_event(p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_phone_event(p) $$;
create or replace function public.server_phone_sent(p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_phone_sent(p) $$;
create or replace function public.server_phone_due(p_limit integer default 20) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_phone_due(p_limit) $$;
create or replace function public.server_phone_summary(p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_phone_summary(p) $$;
create or replace function public.server_phone_ai_log(p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_phone_ai_log(p) $$;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['phone_our_number', 'phone_current_booking', 'phone_match', 'phone_thread_for', 'phone_sms_vars',
              'phone_quiet_end', 'phone_outbox_put', 'phone_sms_from_email', 'phone_on_duty', 'phone_fn_held', 'phone_missed', 'server_phone_event',
              'server_phone_sent', 'server_phone_due', 'phone_ai_budget', 'server_phone_ai_log', 'server_phone_summary', 'phone_item', 'phone_thread_row',
              'phone_inbox', 'phone_thread', 'phone_timeline', 'phone_renter_search', 'phone_staff_do', 'job_phone_housekeeping', 'ops85']))
        or (n.nspname = 'public' and p.proname = any (array['server_phone_event', 'server_phone_sent', 'server_phone_due', 'server_phone_summary', 'server_phone_ai_log']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- the renamed door keeps its privileges; the new one gets the same
do $$
declare
  g text;
begin
  revoke all on function app.door(uuid, text, text, text, jsonb) from public, anon, authenticated;
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.door_pre0085(uuid, text, text, text, jsonb)'::regprocedure, 'execute') then
      execute format('grant execute on function app.door(uuid, text, text, text, jsonb) to %I', g);
    end if;
  end loop;
end $$;
