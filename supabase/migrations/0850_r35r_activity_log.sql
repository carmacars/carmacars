-- 0850_r35r_activity_log.sql
-- Release 35, part R (docs/changes/2026-11-08-r35-activity-log.md). The owner, November 8: "Our renters message and
-- history tab needs to be just combined with all website usage messages calls everything maybe with small little filters
-- for each type of usage, but having everything as one big log as default."
--   One read, renter_activity: everything about a renter (or one booking) in one time-ordered log, newest first, 50 a page
--   with a cursor for Older. Types (each a filter chip): email (emails and account messages, both ways, and the emails the
--   platform sent), text (texts both ways), chat (live chat lines), call (calls with their summaries and next steps), note
--   (renter notes, 0800), booking (booking events), payment (payments and refunds), document (documents, identity checks,
--   signatures), visit (visits to the site, what they did there, and the signals).
--   Who: an Admin; office staff (customer service, Sales, Fleet, Finance) who may see the renter, as for the notes
--   (app.renter_notes_ok). A booking's log: an Admin, or staff who may email that booking's renter (app.booking_email_problem)
--   and see the renter. Payments show to Admins, customer service, Sales and Finance (as the booking's Money section). No email address or phone number is
--   in the log (the conversation and the contact buttons of the page have them, as before).
-- No applied migration is edited; the door is wrapped (door_pre0850).
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

-- the types of the log, in the order of the filter chips
create or replace function app.activity_types() returns text[]
language sql immutable as $$
  select array['email', 'text', 'chat', 'call', 'note', 'booking', 'payment', 'document', 'visit']
$$;

-- a code as words, the first letter capital ("offer_sent" is "Offer sent")
create or replace function app.activity_words(p text) returns text
language sql immutable as $$
  select case when p is null or p = '' then p else upper(left(replace(p, '_', ' '), 1)) || substr(replace(p, '_', ' '), 2) end
$$;

create index if not exists messages_renter_occurred_idx on messages (renter_id, occurred_at desc);
create index if not exists notification_outbox_renter_idx on notification_outbox (renter_id, created_at desc) where renter_id is not null;
create index if not exists chat_conversations_renter_idx on chat_conversations (renter_id) where renter_id is not null;
create index if not exists visitor_sessions_renter_idx on visitor_sessions (renter_id, started_at desc) where renter_id is not null;
create index if not exists visitor_signals_renter_idx on visitor_signals (renter_id, last_at desc) where renter_id is not null;

create or replace function app.renter_activity(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_renter uuid := nullif(coalesce(p ->> 'renter_id', p ->> 'renter', ''), '')::uuid;
  v_key text := nullif(btrim(coalesce(p ->> 'booking', p ->> 'booking_id', '')), '');
  b bookings;
  v_from timestamptz := '-infinity';
  v_to timestamptz := 'infinity';
  v_admin boolean := app.user_is_admin(p_by);
  v_money boolean;
  v_types text[];
  v_q text := lower(btrim(coalesce(p ->> 'q', '')));
  v_before timestamptz := nullif(p ->> 'before', '')::timestamptz;
  v_before_k text := coalesce(p ->> 'before_k', '');
  v_limit integer := greatest(1, least(coalesce(nullif(p ->> 'limit', '')::integer, 50), 100));
  v_bookings uuid[];
  v_items jsonb;
  v_more boolean;
begin
  if v_key is not null then
    select * into b from bookings where id::text = v_key or booking_number = upper(v_key);
    if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
    if not v_admin and (app.booking_email_problem(p_by, b) is not null or (b.renter_id is not null and not app.va_sees_renter(b.renter_id))) then
      raise exception 'This booking''s activity is not open to you' using errcode = '42501';
    end if;
    v_renter := b.renter_id;
    -- the booking's own items, and the renter's items around it that belong to no other booking
    v_from := least(b.created_at, b.pickup_at) - interval '30 days';
    v_to := greatest(b.return_at, coalesce(b.checked_in_at, b.return_at)) + interval '30 days';
  elsif not app.renter_notes_ok(p_by, v_renter) then
    raise exception 'Open this renter''s record first' using errcode = '42501';
  end if;
  v_money := v_admin or app.va_active_fn(p_by) in ('cs', 'sales', 'finance');
  select coalesce(array_agg(t), app.activity_types()) into v_types
    from unnest(string_to_array(coalesce(nullif(p ->> 'types', ''), nullif(p ->> 'type', ''), ''), ',')) t
   where t = any (app.activity_types());
  if not v_money then v_types := array_remove(v_types, 'payment'); end if;
  if length(v_q) > 100 then v_q := left(v_q, 100); end if;
  v_bookings := case when b.id is not null then array[b.id]
                     else coalesce((select array_agg(x.id) from bookings x where x.renter_id = v_renter), '{}'::uuid[]) end;

  with raw as (
    -- emails and account messages written to or by the renter
    select 'email:' || m.id as k, 'email' as type, m.occurred_at as at,
           case when m.direction = 'inbound' then (case m.channel when 'portal' then 'Message from the renter' else 'Email from the renter' end)
                else (case m.channel when 'portal' then 'Message to the renter' else 'Email to the renter' end) end as title,
           concat_ws(': ', nullif(m.subject, ''), left(coalesce(m.body, ''), 600)) as body,
           case when m.direction = 'inbound' then 'in' else 'out' end as dir,
           case when m.direction = 'inbound' then null else coalesce((select u.full_name from users u where u.id = m.sent_by), 'CarmaCars') end as who,
           m.booking_id, null::uuid as ref, null::jsonb as extra
      from messages m
     where 'email' = any (v_types) and m.channel in ('email', 'portal')
       and m.related_table is distinct from 'tasks' and m.related_table is distinct from 'notification_outbox'
       and coalesce(m.template_code, '') <> 'T7'
       and ((b.id is null and (m.renter_id = v_renter or m.booking_id = any (v_bookings)))
            or (b.id is not null and (m.booking_id = b.id or (m.booking_id is null and m.renter_id = v_renter and m.occurred_at between v_from and v_to))))
    union all
    -- the emails the platform sent the renter (the outbox)
    select 'outbox:' || o.id, 'email', coalesce(o.sent_at, o.created_at), 'Email sent: ' || coalesce(nullif(app.render_text(c.subject, o.payload), ''), o.code),
           case when o.status = 'sent' then null else 'Status: ' || o.status || coalesce(' (' || o.status_reason || ')', '') end,
           'out', 'CarmaCars', o.booking_id, null::uuid, jsonb_build_object('status', o.status, 'code', o.code)
      from notification_outbox o join notification_catalogue c on c.code = o.code
     where 'email' = any (v_types) and o.audience not like 'staff\_%' and o.channel in ('email', 'both')
       and ((b.id is null and (o.renter_id = v_renter or o.booking_id = any (v_bookings)))
            or (b.id is not null and (o.booking_id = b.id or (o.booking_id is null and o.renter_id = v_renter and o.created_at between v_from and v_to))))
    union all
    -- texts and calls (Quo)
    select case when a.kind = 'call' then 'call:' else 'text:' end || a.id, case when a.kind = 'call' then 'call' else 'text' end, a.started_at,
           case when a.kind = 'call' then (case when a.missed then 'Missed call' when a.direction = 'in' then 'Call from the renter' else 'Call to the renter' end)
                else (case when a.direction = 'in' then 'Text from the renter' else 'Text to the renter' end) end,
           case when a.kind = 'call' then nullif(concat_ws(' ', coalesce(a.quo_summary ->> 0, a.ai_summary), case when a.voicemail_text is not null then 'Voicemail: ' || a.voicemail_text end), '')
                else left(coalesce(a.body, ''), 600) end,
           a.direction, (select u.full_name from users u where u.id = coalesce(a.sent_by, a.staff_user_id)), a.booking_id, a.thread_id,
           case when a.kind = 'call' then jsonb_build_object('missed', a.missed, 'duration', a.duration_seconds, 'summary_by', case when a.quo_summary is not null then 'quo' when a.ai_summary is not null then 'ai' end,
             'next_steps', a.next_steps) end
      from phone_activity a join phone_threads t on t.id = a.thread_id
     where (('call' = any (v_types) and a.kind = 'call') or ('text' = any (v_types) and a.kind = 'text'))
       and ((b.id is null and (a.renter_id = v_renter or t.renter_id = v_renter))
            or (b.id is not null and (a.booking_id = b.id or (a.booking_id is null and (a.renter_id = v_renter or t.renter_id = v_renter) and a.started_at between v_from and v_to))))
    union all
    -- texts kept as messages (WhatsApp and texts sent before Quo)
    select 'sms:' || m.id, 'text', m.occurred_at, case when m.direction = 'inbound' then 'Text from the renter' else 'Text to the renter' end,
           left(coalesce(m.body, ''), 600), case when m.direction = 'inbound' then 'in' else 'out' end,
           case when m.direction = 'inbound' then null else (select u.full_name from users u where u.id = m.sent_by) end, m.booking_id, null::uuid, null::jsonb
      from messages m
     where 'text' = any (v_types) and m.channel in ('sms', 'whatsapp') and m.related_table is distinct from 'tasks'
       and ((b.id is null and (m.renter_id = v_renter or m.booking_id = any (v_bookings)))
            or (b.id is not null and (m.booking_id = b.id or (m.booking_id is null and m.renter_id = v_renter and m.occurred_at between v_from and v_to))))
    union all
    -- live chat, line by line
    select 'chat:' || cm.id, 'chat', cm.at,
           case cm.sender when 'visitor' then 'Live chat: the renter' when 'ai' then 'Live chat: the assistant' when 'staff' then 'Live chat: staff' else 'Live chat' end,
           left(cm.body, 600), case when cm.sender = 'visitor' then 'in' else 'out' end,
           case when cm.sender = 'staff' then (select u.full_name from users u where u.id = cm.staff_id) end, c.booking_id, c.id, jsonb_build_object('chat', c.number)
      from chat_messages cm join chat_conversations c on c.id = cm.conversation_id
     where 'chat' = any (v_types) and c.renter_id = v_renter
       and (b.id is null or c.booking_id = b.id or (c.booking_id is null and cm.at between v_from and v_to))
    union all
    -- renter notes (0800)
    select 'note:' || n.id, 'note', n.created_at, 'Note', n.body, null, n.author_name, n.booking_id, n.call_id, jsonb_build_object('role', n.author_role)
      from renter_notes n
     where 'note' = any (v_types) and n.renter_id = v_renter and n.removed_at is null
       and (b.id is null or n.booking_id = b.id or (n.booking_id is null and n.created_at between v_from and v_to))
    union all
    -- booking events
    select 'event:' || e.id, 'booking', e.created_at, app.activity_words(e.kind),
           concat_ws(' ', case when v_admin and e.from_status is not null and e.to_status is not null and e.from_status <> e.to_status
                                 then replace(e.from_status, '_', ' ') || ' to ' || replace(e.to_status, '_', ' ') || '.' end, nullif(e.note, '')),
           null, coalesce((select u.full_name from users u where u.id = e.actor_user_id), e.actor_type), e.booking_id, null::uuid, null::jsonb
      from booking_events e
     where 'booking' = any (v_types) and e.booking_id = any (v_bookings)
    union all
    -- payments and refunds (Admins, customer service, Sales and Finance)
    select 'payment:' || y.id, 'payment', coalesce(y.processed_at, y.created_at),
           app.activity_words(y.kind) || ': ' || replace(y.purpose, '_', ' '),
           to_char(y.amount_cents / 100.0, 'FM$999,999,990.00') || ', ' || y.status || coalesce(', card ending ' || y.card_last4, '') || coalesce('. ' || y.reason_note, ''),
           null, (select u.full_name from users u where u.id = y.created_by), y.booking_id, null::uuid, jsonb_build_object('status', y.status, 'cents', y.amount_cents)
      from payments y
     where 'payment' = any (v_types) and y.booking_id = any (v_bookings) and y.purpose not in ('owner_upfront', 'owner_fees')
    union all
    select 'refund:' || f.id, 'payment', coalesce(f.paid_at, f.approved_at, f.created_at), 'Refund: ' || replace(f.reason, '_', ' '),
           to_char(f.amount_cents / 100.0, 'FM$999,999,990.00') || ', ' || f.status || coalesce('. ' || f.note, ''),
           'out', null, f.booking_id, null::uuid, jsonb_build_object('status', f.status, 'cents', f.amount_cents)
      from refunds f
     where 'payment' = any (v_types) and f.booking_id = any (v_bookings)
    union all
    -- documents, identity checks and signatures
    select 'document:' || d.id, 'document', d.created_at, 'Document added: ' || coalesce(nullif(d.title, ''), replace(d.kind::text, '_', ' ')),
           case when d.review_status is not null then 'Review: ' || replace(d.review_status, '_', ' ') || coalesce(' (' || d.review_note || ')', '') end,
           null, (select u.full_name from users u where u.id = d.uploaded_by), d.booking_id, d.id, null::jsonb
      from documents d
     where 'document' = any (v_types) and d.removed_at is null and d.purged_at is null
       and ((b.id is null and (d.renter_id = v_renter or d.booking_id = any (v_bookings)))
            or (b.id is not null and (d.booking_id = b.id or (d.booking_id is null and d.renter_id = v_renter and d.created_at between v_from and v_to))))
    union all
    select 'identity:' || iv.id, 'document', coalesce(iv.verified_at, iv.created_at),
           'Identity check: ' || replace(iv.status::text, '_', ' '),
           concat_ws(' ', dr.full_name || ',', replace(iv.method, '_', ' ') || '.', nullif(iv.failure_reason, '')),
           null, (select u.full_name from users u where u.id = iv.verified_by), iv.booking_id, null::uuid, null::jsonb
      from identity_verifications iv join drivers dr on dr.id = iv.driver_id
     where 'document' = any (v_types) and dr.renter_id = v_renter
       and (b.id is null or iv.booking_id = b.id or (iv.booking_id is null and iv.created_at between v_from and v_to))
    union all
    select 'signed:' || s.id, 'document', s.signed_at, 'Signed: ' || replace(coalesce(s.context, 'documents'), '_', ' '),
           coalesce(s.signer_name, '') || coalesce(' (' || replace(s.signer_role, '_', ' ') || ')', ''),
           'in', null, s.booking_id, null::uuid, null::jsonb
      from esign_sessions s
     where 'document' = any (v_types) and s.signed_at is not null and s.booking_id = any (v_bookings)
    union all
    -- the website: each visit, what they did there (not every page view), and the signals
    select 'visit:' || vs.id, 'visit', vs.started_at, 'Visit to the site',
           concat_ws(', ', coalesce(vs.page_views, 0) || case when coalesce(vs.page_views, 0) = 1 then ' page' else ' pages' end,
                     'landed on ' || app.path_label(vs.landing_path), case when coalesce(cardinality(vs.cars_viewed), 0) > 0 then cardinality(vs.cars_viewed) || ' cars looked at' end,
                     case when vs.duration_s > 0 then (vs.duration_s / 60) || ' min' end, nullif(vs.device, '')),
           'in', null, vs.current_booking_id, vs.id, jsonb_build_object('visit_number', vs.visit_number)
      from visitor_sessions vs
     where 'visit' = any (v_types) and vs.renter_id = v_renter and (b.id is null or vs.started_at between v_from and v_to)
    union all
    select 'site:' || ve.id, 'visit', ve.at, app.activity_words(ve.kind),
           concat_ws(', ', app.path_label(ve.path), case when ve.vehicle_id is not null then app.vehicle_name(ve.vehicle_id) end),
           'in', null, ve.booking_id, ve.session_id, null::jsonb
      from visitor_events ve join visitor_sessions vs on vs.id = ve.session_id
     where 'visit' = any (v_types) and vs.renter_id = v_renter and ve.kind not in ('page_view', 'page_leave')
       and (b.id is null or ve.booking_id = b.id or (ve.booking_id is null and ve.at between v_from and v_to))
    union all
    select 'signal:' || g.id, 'visit', g.last_at, 'Signal: ' || g.label,
           case when g.times > 1 then g.times || ' times' end || case when g.resolved_at is not null then ' (handled)' else '' end,
           'in', null, g.booking_id, g.session_id, null::jsonb
      from visitor_signals g
     where 'visit' = any (v_types) and g.renter_id = v_renter
       and (b.id is null or g.booking_id = b.id or (g.booking_id is null and g.last_at between v_from and v_to))
  ), page as (
    select r.* from raw r
     where r.at is not null
       and (v_before is null or (r.at, r.k) < (v_before, v_before_k))
       and (v_q = '' or position(v_q in lower(coalesce(r.title, '') || ' ' || coalesce(r.body, '') || ' ' || coalesce(r.who, ''))) > 0)
     order by r.at desc, r.k desc
     limit v_limit + 1
  )
  select coalesce(jsonb_agg(jsonb_build_object('k', x.k, 'type', x.type, 'at', x.at, 'title', x.title, 'body', nullif(x.body, ''), 'dir', x.dir, 'by', x.who,
           'booking_number', (select bb.booking_number from bookings bb where bb.id = x.booking_id), 'ref', x.ref, 'extra', x.extra) order by x.at desc, x.k desc), '[]'::jsonb)
    into v_items from page x;

  v_more := jsonb_array_length(v_items) > v_limit;
  if v_more then v_items := v_items - v_limit; end if;
  return jsonb_build_object(
    'renter_id', v_renter, 'booking', b.booking_number, 'types', to_jsonb(case when v_money then app.activity_types() else array_remove(app.activity_types(), 'payment') end),
    'items', v_items, 'more', v_more,
    'next', case when v_more then jsonb_build_object('before', v_items -> (v_limit - 1) ->> 'at', 'before_k', v_items -> (v_limit - 1) ->> 'k') end);
end $$;

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0850;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('admin_read', 'va_read', 'ops_read') and p_name = 'renter_activity' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.renter_activity(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre0850(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0850(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['activity_types', 'activity_words', 'renter_activity', 'door_pre0850'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
