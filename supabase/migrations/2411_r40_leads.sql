-- 2411_r40_leads.sql
-- Release 40: the whole person on the lead, signals across every interaction, and bulk assignment of leads.
-- The owner: "On the leads page it should show the entire context of that renter. All previous leads need to be assigned in
-- bulk." And: "Signals are for an entire lead/renter's interaction with us, calls and texts and everything else included."
--   1. One person behind a lead or a renter (app.person_keys): the lead, the renter it matches (a chat or a phone thread linked
--      to the lead, else a renter with the lead's email or mobile, never a merged one), every other lead with the same email or
--      phone, and those emails and phones.
--   2. Signals for the person, not for one lead row: app.person_signals (a timeline, newest first) and app.person_behaviour
--      (the counts the intent score reads), from the sources that exist: Quo calls (in, out, missed, duration) and texts both
--      ways, WhatsApp / Messenger / Instagram (the auto-replies' log, 2110), the site chat, emails they wrote, email links
--      opened, site visits and car views, offers, quotes, payment and change pages viewed (visitor_events), booking requests,
--      bookings, spend, cancellations and reviews, and their leads. app.intent_inputs reads the same person (1506/1703's texts
--      kept), and app.intent_score adds the reasons of the new counts. A lead's and its renter's intent are now the same person.
--   3. The renter context on the lead (read lead_context {lead}): contact and preferred name, account and verification
--      (licence verified yes or no, never a number), every booking with its car, dates, status, total and open balance, the
--      balance and deposit (0800's readers), open requests and offers sent, earlier leads, the renter's activity log (0850),
--      notes (0800), roles (0470), reviews, incidents and claims (numbers and status only), "Helped by" (2330) with who claimed,
--      held or was assigned the lead, the intent and the signals timeline. Whoever may open the lead (app.sl_lead_for: an Admin,
--      Sales, customer service) reads it. Staff outside the renter's window (app.va_sees_renter) see the full context only while
--      the lead is theirs (their claim, their hold or an Admin's assignment): that opening is logged in data_access_log as Open
--      with a reason does (24 hours). Otherwise they see the contact, the account and the counts, and are told to claim the lead.
--   4. Bulk assignment (do leads_bulk_assign, Admin only, at most 500 leads a call): chosen leads or a filter (status, source,
--      type, age, assigned, words, created before today), to a staff member who can take leads (active, fully onboarded,
--      Sales: customer service, Fleet and Finance get no sales credit, 2330) or back to the pool. An assignment made this way is
--      an Admin assignment, not a claim and not a hold: it does not run out; nobody else claims the lead, Next lead skips it,
--      and the assignee's claims on it are not paced or capped; a customer service or fleet call hold still works over it
--      (2320) and gives the lead back to the assignee when it ends. Logged per lead (lead_claim_log assign or release) and once
--      in the audit log. preview: true counts the matches and changes nothing.
-- No applied migration is edited: functions are wrapped or patched in place (their grants copied).
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
  if position(p_old in d) = 0 then raise exception '2411: the text to change was not found in %: %', p_sig, left(p_old, 120); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the columns, the log's words
alter table leads add column if not exists admin_assigned_by uuid references users (id) on delete set null,
                  add column if not exists admin_assigned_at timestamptz;
comment on column leads.admin_assigned_at is 'Bulk assignment (2411): set when an Admin assigned the lead to assigned_to. Not a claim and not a hold: it does not run out; cleared when the lead moves to someone else or back to the pool.';
create index if not exists leads_open_created_idx on leads (created_at) where handled_at is null;

-- the log's actions plus assign (whatever an earlier migration added is kept)
do $$
declare
  d text;
  v text[];
begin
  select pg_get_constraintdef(oid) into d from pg_constraint where conrelid = 'lead_claim_log'::regclass and conname = 'lead_claim_log_action_check';
  v := array(select m[1] from regexp_matches(coalesce(d, ''), '''([a-z_]+)''', 'g') m);
  if not ('assign' = any (v)) then v := v || 'assign'::text; end if;
  alter table lead_claim_log drop constraint if exists lead_claim_log_action_check;
  execute format('alter table lead_claim_log add constraint lead_claim_log_action_check check (action = any (%L::text[]))', v);
end $$;

-- ================================================================ 2. the person
create or replace function app.person_keys(p_renter uuid, p_lead uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  l leads;
  r renters;
  v_renter uuid := p_renter;
  v_emails text[];
  v_phones text[];
  v_leads uuid[];
begin
  if p_lead is not null then select * into l from leads where id = p_lead; end if;
  if v_renter is null and l.id is not null then
    select x.rid into v_renter from (
      select c.renter_id rid, 0 pri, c.created_at at from chat_conversations c where c.lead_id = l.id and c.renter_id is not null
      union all
      select t.renter_id, 0, t.created_at from phone_threads t where t.lead_id = l.id and t.renter_id is not null
      union all
      select rr.id, 1, rr.created_at from renters rr
       where (nullif(btrim(l.email), '') is not null and lower(rr.email) = lower(btrim(l.email)))
          or (app.phone_e164(l.phone) is not null and app.phone_e164(rr.mobile) = app.phone_e164(l.phone))
    ) x join renters y on y.id = x.rid and y.merged_into is null
    order by x.pri, (select count(*) from bookings b where b.renter_id = x.rid) desc, x.at desc
    limit 1;
  end if;
  if v_renter is not null then select * into r from renters where id = v_renter; end if;
  v_emails := array(select distinct e from unnest(array[lower(nullif(btrim(l.email), '')), lower(nullif(btrim(r.email), ''))]) e where e is not null);
  v_phones := array(select distinct x from unnest(array[app.phone_e164(l.phone), app.phone_e164(r.mobile)]) x where x is not null);
  v_leads := array(select x.id from leads x
                    where (x.id = l.id or lower(btrim(x.email)) = any (v_emails) or app.phone_e164(x.phone) = any (v_phones))
                      and (x.id = l.id or (x.status <> 'spam' and x.kind <> 'turo_guest'))
                    order by x.created_at desc limit 100);
  return jsonb_build_object('renter_id', r.id, 'user_id', r.user_id, 'lead_id', l.id, 'leads', to_jsonb(v_leads), 'emails', to_jsonb(v_emails), 'phones', to_jsonb(v_phones));
end $$;

create or replace function app.pk_uuids(k jsonb, p_key text) returns uuid[]
language sql immutable as $$ select coalesce(array(select jsonb_array_elements_text(coalesce(k -> p_key, '[]'::jsonb))::uuid), '{}'::uuid[]) $$;
create or replace function app.pk_texts(k jsonb, p_key text) returns text[]
language sql immutable as $$ select coalesce(array(select jsonb_array_elements_text(coalesce(k -> p_key, '[]'::jsonb))), '{}'::text[]) $$;

-- the person's site visits: by the renter, their account, an email they gave, or a chat of theirs
create or replace function app.person_sessions(k jsonb, p_days integer default 365) returns setof visitor_sessions
language sql stable security definer set search_path = public, app as $$
  select s.* from visitor_sessions s
   where s.started_at > now() - make_interval(days => p_days)
     and ((k ->> 'renter_id') is not null and s.renter_id = (k ->> 'renter_id')::uuid
          or (k ->> 'user_id') is not null and s.user_id = (k ->> 'user_id')::uuid
          or lower(s.known_email) = any (app.pk_texts(k, 'emails'))
          or s.visitor_id in (select c.visitor_id from chat_conversations c
                               where c.visitor_id is not null and (c.lead_id = any (app.pk_uuids(k, 'leads'))
                                     or ((k ->> 'renter_id') is not null and c.renter_id = (k ->> 'renter_id')::uuid))))
$$;

-- the person's Quo calls and texts: linked to the renter or one of the leads, or on a thread with one of their numbers
create or replace function app.person_phone(k jsonb, p_days integer default 365) returns setof phone_activity
language sql stable security definer set search_path = public, app as $$
  select a.* from phone_activity a
   where a.started_at > now() - make_interval(days => p_days)
     and ((k ->> 'renter_id') is not null and a.renter_id = (k ->> 'renter_id')::uuid
          or a.lead_id = any (app.pk_uuids(k, 'leads'))
          or a.thread_id in (select t.id from phone_threads t where t.number = any (app.pk_texts(k, 'phones'))
                              or ((k ->> 'renter_id') is not null and t.renter_id = (k ->> 'renter_id')::uuid)
                              or t.lead_id = any (app.pk_uuids(k, 'leads'))))
$$;

-- ================================================================ 3. the signals
-- The counts the intent score reads, for the whole person.
create or replace function app.person_behaviour(k jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_renter uuid := (k ->> 'renter_id')::uuid;
  v_leads uuid[] := app.pk_uuids(k, 'leads');
  v_emails text[] := app.pk_texts(k, 'emails');
  v_keys text[] := array(select app.intent_phone_key(x) from unnest(app.pk_texts(k, 'phones')) x);
  v jsonb;
  s record;
begin
  select count(*) visits, coalesce(sum(x.page_views), 0) pages, bool_or(x.last_seen_at > now() - interval '24 hours') recent, max(x.score) score,
         array_agg(x.id) ids
    into s from app.person_sessions(k, 30) x;
  v := jsonb_build_object('visits', s.visits, 'pages', s.pages, 'recent', coalesce(s.recent, false), 'visitor_score', s.score,
    'cars', (select count(distinct c) from app.person_sessions(k, 30) x, unnest(x.cars_viewed) c),
    'offers_viewed', (select count(*) from visitor_events e where e.session_id = any (coalesce(s.ids, '{}')) and e.kind in ('offer_viewed', 'quote_seen', 'change_viewed') and e.at > now() - interval '14 days'),
    'pay_viewed', (select count(*) from visitor_events e where e.session_id = any (coalesce(s.ids, '{}')) and e.kind = 'pay_viewed' and e.at > now() - interval '14 days'),
    'email_opens', (select count(*) from visitor_events e where e.session_id = any (coalesce(s.ids, '{}')) and e.kind = 'email_link_opened'),
    'requests', (select count(*) from bookings b where b.renter_id = v_renter and b.created_at > now() - interval '14 days' and not coalesce(b.is_placeholder, false)),
    'conversations', (select count(distinct a.thread_id) from app.person_phone(k, 30) a)
                     + (select count(*) from chat_conversations c where c.created_at > now() - interval '30 days' and (c.lead_id = any (v_leads) or c.renter_id = v_renter))
                     + (select count(distinct q.channel) from auto_replies q where q.created_at > now() - interval '30 days' and q.channel in ('whatsapp', 'messenger', 'instagram')
                          and (app.intent_phone_key(q.sender) = any (v_keys) or lower(q.sender) = any (v_emails))),
    'email_replies', (select count(*) from messages m where m.direction = 'inbound' and m.channel = 'email' and m.occurred_at > now() - interval '30 days'
                        and (m.renter_id = v_renter or lower(m.from_address) = any (v_emails))),
    'rentals', (select count(*) from bookings b where b.renter_id = v_renter and b.status::text in ('returned', 'closed') and not coalesce(b.is_placeholder, false)),
    'spend_cents', (select coalesce(sum(app.booking_paid_cents(b.id)), 0) from bookings b where b.renter_id = v_renter and not coalesce(b.is_placeholder, false)
                      and b.status::text in ('confirmed', 'on_rent', 'returned', 'closed')),
    'cancellations', (select count(*) from bookings b where b.renter_id = v_renter and b.status::text in ('cancelled', 'no_show') and not coalesce(b.is_placeholder, false)),
    'review_avg', (select round(avg(rv.rating), 1) from reviews rv where rv.renter_id = v_renter),
    'leads', cardinality(v_leads));
  return v;
end $$;

-- The person's timeline of signals, newest first: [{at, type, title, detail, dir}]
create or replace function app.person_signals(k jsonb, p_limit integer default 80) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with p as (select (k ->> 'renter_id')::uuid renter, app.pk_uuids(k, 'leads') leads, app.pk_texts(k, 'emails') emails,
                    array(select app.intent_phone_key(x) from unnest(app.pk_texts(k, 'phones')) x) keys),
  ses as (select s.* from app.person_sessions(k) s order by s.started_at desc limit 40),
  ev as (
    -- calls and texts (Quo)
    select a.started_at at, case when a.kind = 'call' then 'call' else 'text' end type,
           case when a.kind = 'call' then (case when a.missed then 'Missed call' when a.direction = 'in' then 'Call from them' else 'Call to them' end)
                else (case when a.direction = 'in' then 'Text from them' else 'Text to them' end) end title,
           case when a.kind = 'call' then nullif(concat_ws(' · ', case when a.duration_seconds > 0 then (a.duration_seconds / 60) || ' min ' || (a.duration_seconds % 60) || ' s' end,
                                                  left(coalesce(a.quo_summary ->> 0, a.ai_summary, a.voicemail_text), 200)), '')
                else left(a.body, 200) end detail, a.direction dir
      from (select * from app.person_phone(k) x order by x.started_at desc limit 60) a
    union all
    -- WhatsApp, Messenger, Instagram (the auto-replies' log)
    select q.created_at, q.channel, case q.channel when 'whatsapp' then 'WhatsApp message' when 'messenger' then 'Messenger message' else 'Instagram message' end,
           left(q.question, 200), 'in'
      from auto_replies q, p
     where q.channel in ('whatsapp', 'messenger', 'instagram') and (app.intent_phone_key(q.sender) = any (p.keys) or lower(q.sender) = any (p.emails))
    union all
    -- the site chat
    select c.created_at, 'chat', 'Live chat', (select left(m.body, 200) from chat_messages m where m.conversation_id = c.id and m.sender = 'visitor' order by m.at limit 1), 'in'
      from chat_conversations c, p where c.lead_id = any (p.leads) or c.renter_id = p.renter
    union all
    -- emails they wrote
    select m.occurred_at, 'email', 'Email from them', left(concat_ws(': ', nullif(m.subject, ''), m.body), 200), 'in'
      from messages m, p where m.direction = 'inbound' and m.channel = 'email' and (m.renter_id = p.renter or lower(m.from_address) = any (p.emails))
    union all
    -- site visits
    select s.started_at, 'visit', 'Visited the site', concat_ws(' · ', s.page_views || ' pages', nullif(cardinality(s.cars_viewed), 0) || ' cars', case when s.from_ad then 'from an ad' end), null
      from ses s
    union all
    -- what they looked at: cars, offers, quotes, the payment and change pages, email links
    select e.at, e.kind, case e.kind when 'car_view' then 'Looked at a car' when 'offer_viewed' then 'Opened an offer' when 'quote_seen' then 'Saw a price quote'
                               when 'pay_viewed' then 'Opened the payment page' when 'change_viewed' then 'Opened a change to a booking'
                               when 'email_link_opened' then 'Opened a link in an email' else 'Sent a booking request' end,
           coalesce(app.vehicle_name(e.vehicle_id), (select b.booking_number from bookings b where b.id = e.booking_id)), null
      from visitor_events e join ses s on s.id = e.session_id
     where e.kind in ('car_view', 'offer_viewed', 'quote_seen', 'pay_viewed', 'change_viewed', 'email_link_opened', 'request_submitted')
    union all
    -- bookings and cancellations
    select b.created_at, 'booking', 'Booking ' || b.booking_number || ' requested',
           concat_ws(' · ', app.vehicle_name(b.vehicle_id), to_char(b.pickup_at at time zone 'America/Toronto', 'Mon DD') || ' to ' || to_char(b.return_at at time zone 'America/Toronto', 'Mon DD')), null
      from bookings b, p where b.renter_id = p.renter and not coalesce(b.is_placeholder, false)
    union all
    select b.updated_at, 'cancelled', case when b.status::text = 'no_show' then 'No-show on ' else 'Cancelled ' end || b.booking_number, app.vehicle_name(b.vehicle_id), null
      from bookings b, p where b.renter_id = p.renter and b.status::text in ('cancelled', 'no_show') and not coalesce(b.is_placeholder, false)
    union all
    select b.checked_in_at, 'rented', 'Returned ' || b.booking_number, app.vehicle_name(b.vehicle_id), null
      from bookings b, p where b.renter_id = p.renter and b.checked_in_at is not null and b.status::text in ('returned', 'closed')
    union all
    -- reviews and leads
    select rv.created_at, 'review', 'Left a ' || rv.rating || '-star review', left(coalesce(rv.title, rv.body), 200), null
      from reviews rv, p where rv.renter_id = p.renter
    union all
    select l.created_at, 'lead', 'Lead: ' || app.sl_source(l), left(l.message, 200), 'in'
      from leads l, p where l.id = any (p.leads)
  )
  select coalesce(jsonb_agg(jsonb_build_object('at', x.at, 'type', x.type, 'title', x.title, 'detail', x.detail, 'dir', x.dir) order by x.at desc), '[]'::jsonb)
    from (select * from ev where at is not null order by at desc limit greatest(1, least(p_limit, 200))) x
$$;

-- the intent: the same person whether the subject is the renter or one of their leads
create or replace function app.intent_inputs(p_kind text, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  k jsonb := app.person_keys(case when p_kind = 'renter' then p_id end, case when p_kind = 'lead' then p_id end);
  v_renter uuid := (k ->> 'renter_id')::uuid;
  v_leads uuid[] := app.pk_uuids(k, 'leads');
  v_emails text[] := app.pk_texts(k, 'emails');
  v_keys text[] := array(select app.intent_phone_key(x) from unnest(app.pk_texts(k, 'phones')) x);
  v_texts text[];
begin
  v_texts := array(
    select x from (
      select concat_ws(' ', a.body, a.voicemail_text, a.ai_summary, a.quo_summary, a.next_steps::text, a.transcript::text) x, a.started_at at
        from app.person_phone(k, 60) a
      union all
      select coalesce(m.subject, '') || ' ' || coalesce(m.body, ''), m.occurred_at from messages m
       where m.direction = 'inbound' and m.occurred_at > now() - interval '60 days' and (m.renter_id = v_renter or lower(m.from_address) = any (v_emails))
      union all
      select cm.body, cm.at from chat_messages cm join chat_conversations c on c.id = cm.conversation_id
       where (c.renter_id = v_renter or c.lead_id = any (v_leads)) and cm.sender = 'visitor' and cm.at > now() - interval '60 days'
      union all
      select q.question, q.created_at from auto_replies q
       where q.channel in ('whatsapp', 'messenger', 'instagram') and q.question is not null and q.created_at > now() - interval '60 days'
         and (app.intent_phone_key(q.sender) = any (v_keys) or lower(q.sender) = any (v_emails))
      union all
      select concat_ws(' ', l.message, l.pipeline_note, l.vehicle_text, l.payload::text), l.created_at from leads l where l.id = any (v_leads)
      union all
      select lc.note, lc.at from lead_contacts lc where lc.lead_id = any (v_leads) and nullif(btrim(lc.note), '') is not null and lc.at > now() - interval '60 days'
      union all
      select r.staff_note, coalesce(r.updated_at, r.created_at) from renters r where r.id = v_renter and nullif(btrim(r.staff_note), '') is not null
      union all
      select n.body, n.created_at from renter_notes n where n.renter_id = v_renter and n.removed_at is null and n.created_at > now() - interval '60 days'
      union all
      select concat_ws(' ', b.request_note, b.notes), b.created_at from bookings b
       where b.renter_id = v_renter and not coalesce(b.is_placeholder, false) and b.created_at > now() - interval '60 days'
         and coalesce(nullif(btrim(b.request_note), ''), nullif(btrim(b.notes), '')) is not null
    ) q where nullif(btrim(x), '') is not null order by at desc nulls last limit 80);
  return jsonb_build_object('texts', to_jsonb(v_texts), 'behaviour', app.person_behaviour(k));
end $$;

alter function app.intent_score(jsonb, jsonb) rename to intent_score_pre2411;
create function app.intent_score(p_signals jsonb, p_behaviour jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with base as (select app.intent_score_pre2411(p_signals, p_behaviour) v),
  r as (
    select 'Rented with us before (' || (p_behaviour ->> 'rentals') || ')' l, 10 n where coalesce((p_behaviour ->> 'rentals')::int, 0) > 0
    union all select 'Opened an offer or a quote', 10 where coalesce((p_behaviour ->> 'offers_viewed')::int, 0) > 0
    union all select 'Opened the payment page', 8 where coalesce((p_behaviour ->> 'pay_viewed')::int, 0) > 0
    union all select 'Wrote back by email', 4 where coalesce((p_behaviour ->> 'email_replies')::int, 0) > 0
    union all select 'Opened a link in an email', 3 where coalesce((p_behaviour ->> 'email_opens')::int, 0) > 0
    union all select 'Left a good review', 4 where coalesce((p_behaviour ->> 'review_avg')::numeric, 0) >= 4
    union all select 'Cancelled ' || (p_behaviour ->> 'cancellations') || ' bookings', -10 where coalesce((p_behaviour ->> 'cancellations')::int, 0) >= 2),
  all_r as (
    select x l_j from base, jsonb_array_elements(base.v -> 'reasons') x
    union all select jsonb_build_object('label', l, 'points', n) from r)
  select jsonb_build_object('score', greatest(0, least(100, coalesce(((select v from base) ->> 'score')::int, 0) + coalesce((select sum(n) from r), 0)))::int,
    'reasons', coalesce((select jsonb_agg(l_j order by (l_j ->> 'points')::int desc) from all_r), '[]'::jsonb))
$$;
select pg_temp.copy_grants('app.intent_score(jsonb, jsonb)'::regprocedure, 'app.intent_score_pre2411(jsonb, jsonb)'::regprocedure);

-- ================================================================ 4. the renter context on the lead
-- Who has handled the person: "Helped by" (2330) on every lead and booking of theirs, and who claimed, held or was assigned a lead
create or replace function app.person_handled_by(k jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with rows as (
    select (h ->> 'id')::uuid id, w what
      from (select app.helped_by(null, x) j from unnest(app.pk_uuids(k, 'leads')) x
            union all select app.helped_by(b.id, null) from bookings b where b.renter_id = (k ->> 'renter_id')::uuid) s,
           jsonb_array_elements(s.j) h, jsonb_array_elements_text(h -> 'what') w
    union all
    select g.user_id, case g.action when 'assign' then 'Assigned the lead by an Admin' when 'hold' then 'Handled on a call' when 'reassign' then 'Lead reassigned to them'
                               when 'return' then 'Lead returned to them' else 'Claimed the lead' end
      from lead_claim_log g where g.lead_id = any (app.pk_uuids(k, 'leads')) and g.action in ('claim', 'reassign', 'return', 'hold', 'assign')
    union all
    select b.sales_staff_id, 'Sales on ' || b.booking_number from bookings b where b.renter_id = (k ->> 'renter_id')::uuid and b.sales_staff_id is not null
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', z.id, 'name', app.sl_name(z.id), 'what', z.what) order by app.sl_name(z.id)), '[]'::jsonb)
    from (select r.id, to_jsonb(array_agg(distinct r.what)) what from rows r
           where r.id is not null and not app.staff_is_test(r.id) group by r.id) z
$$;

-- p: {lead}. Everything known about the person behind the lead (see the header).
create or replace function app.lead_context(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  l leads;
  k jsonb;
  r renters;
  u users;
  v_admin boolean := coalesce(app.user_is_admin(p_by), false);
  v_mine boolean;
  v_full boolean;
  v_leads uuid[];
  v_activity jsonb;
  v_base jsonb;
begin
  l := app.sl_lead_for(p_by, nullif(p ->> 'lead', '')::uuid);
  k := app.person_keys(null, l.id);
  v_leads := app.pk_uuids(k, 'leads');
  if (k ->> 'renter_id') is not null then select * into r from renters where id = (k ->> 'renter_id')::uuid; end if;
  if r.user_id is not null then select * into u from users where id = r.user_id; end if;
  v_mine := coalesce(l.assigned_to = p_by, false)
            or exists (select 1 from lead_claims c where c.lead_id = l.id and c.claimed_by = p_by and c.expires_at > now())
            or exists (select 1 from lead_holds h where h.lead_id = l.id and h.held_by = p_by and h.expires_at > now());
  v_full := v_admin or r.id is null or coalesce(app.va_sees_renter(r.id), false) or v_mine;
  -- the lead is theirs: the renter's record opens for them, logged as Open with a reason is
  if not v_admin and r.id is not null and v_full and not coalesce(app.va_sees_renter(r.id), false) then
    insert into data_access_log (user_id, action, renter_id, reason, granted_until)
    values (p_by, 'open', r.id, left('Working lead ' || l.id::text || ' (renter context on the lead)', 300), now() + interval '24 hours');
  end if;

  v_base := jsonb_build_object(
    'lead_id', l.id, 'full', v_full, 'admin', v_admin,
    'why_limited', case when not v_full then 'Claim the lead (or ask an Admin to assign it to you) to see their bookings, messages, notes and signals.' end,
    'renter_id', r.id,
    'contact', jsonb_build_object('name', coalesce(r.legal_name, l.name), 'preferred_name', nullif(btrim(coalesce(u.greeting_name, u.display_name, '')), ''),
                 'email', case when v_full then coalesce(r.email, l.email) else l.email end, 'phone', case when v_full then coalesce(r.mobile, l.phone) else l.phone end,
                 'city', case when v_full then r.city end),
    'account', jsonb_build_object('renter', r.id is not null, 'has_sign_in', u.id is not null, 'email_confirmed', u.email_verified_at is not null,
                 'identity_status', r.identity_status, 'licence_verified', coalesce(r.identity_status::text = 'verified'
                   or exists (select 1 from drivers d where d.renter_id = r.id and d.is_account_holder and d.identity_status::text = 'verified'), false),
                 'blocked', coalesce(r.is_blocked, false), 'since', r.created_at),
    'roles', case when r.id is not null or l.email is not null or l.phone is not null then app.person_tags(r.user_id, r.id, l.email, l.phone) -> 'roles' else '[]'::jsonb end,
    'counts', jsonb_build_object('bookings', (select count(*) from bookings b where b.renter_id = r.id and not coalesce(b.is_placeholder, false)),
                                 'leads', cardinality(v_leads)),
    'intent', case when exists (select 1 from intent_scores s where s.subject_kind = 'lead' and s.subject_id = l.id and s.computed_at > now() - interval '10 minutes')
                   then app.intent_json('lead', l.id) else app.intent_compute('lead', l.id) end);
  if not v_full then return v_base; end if;

  begin
    v_activity := app.renter_activity(p_by, jsonb_build_object('renter_id', r.id, 'limit', 30));
  exception when others then v_activity := null;
  end;
  return v_base || jsonb_build_object(
    'bookings', coalesce((select jsonb_agg(jsonb_build_object('number', b.booking_number, 'car', app.vehicle_name(b.vehicle_id), 'status', b.status,
                    'pickup_at', b.pickup_at, 'return_at', b.return_at, 'total_cents', coalesce(b.total_due_at_booking_cents, b.price_with_tax_cents),
                    'open_cents', case when b.status::text in ('returned', 'closed') then app.lead_context_open(b.id) end,
                    'upcoming', b.pickup_at > now() and b.status::text not in ('cancelled', 'declined', 'expired', 'no_show')) order by b.pickup_at desc)
                  from bookings b where b.renter_id = r.id and not coalesce(b.is_placeholder, false)), '[]'::jsonb),
    'balance', case when r.id is not null then app.caller_balance(r.id) end,
    'deposit', case when r.id is not null then app.caller_deposit(app.caller_booking(r.id)) end,
    'requests', case when r.id is not null then app.caller_requests(r.id) else '[]'::jsonb end,
    'offers', coalesce((select jsonb_agg(jsonb_build_object('booking', b.booking_number, 'version', o.version, 'status', o.status, 'sent_at', o.sent_at,
                    'expires_at', o.expires_at, 'total_cents', o.total_cents, 'car', app.vehicle_name(o.vehicle_id), 'by', app.sl_name(o.sent_by)) order by o.sent_at desc nulls last)
                  from booking_offers o join bookings b on b.id = o.booking_id where b.renter_id = r.id), '[]'::jsonb),
    'leads', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'at', x.created_at, 'source', app.sl_source(x), 'status', x.status, 'outcome', x.sales_outcome,
                    'handled', x.handled_at is not null, 'excerpt', left(x.message, 160), 'this', x.id = l.id) order by x.created_at desc)
                  from leads x where x.id = any (v_leads)), '[]'::jsonb),
    'activity', coalesce(v_activity -> 'items', '[]'::jsonb),
    'notes', case when r.id is not null then app.renter_notes_list(r.id, 20) else '[]'::jsonb end,
    'staff_note', nullif(btrim(r.staff_note), ''),
    'reviews', coalesce((select jsonb_agg(jsonb_build_object('at', rv.created_at, 'rating', rv.rating, 'title', rv.title, 'body', left(rv.body, 300), 'status', rv.status,
                    'booking', (select b.booking_number from bookings b where b.id = rv.booking_id)) order by rv.created_at desc)
                  from reviews rv where rv.renter_id = r.id), '[]'::jsonb),
    'incidents', coalesce((select jsonb_agg(jsonb_build_object('number', i.incident_number, 'kind', i.kind, 'status', i.status, 'at', i.occurred_at, 'booking', b.booking_number,
                    'claims', (select coalesce(jsonb_agg(jsonb_build_object('number', c.claim_number, 'status', c.status)), '[]'::jsonb) from claims c where c.incident_id = i.id)) order by i.occurred_at desc)
                  from incidents i join bookings b on b.id = i.booking_id where b.renter_id = r.id), '[]'::jsonb),
    'handled_by', app.person_handled_by(k),
    'behaviour', app.person_behaviour(k),
    'signals', app.person_signals(k, 80));
end $$;

-- a returned booking's charges not paid; a booking whose money cannot be read shows nothing rather than failing the panel
create or replace function app.lead_context_open(p_booking uuid) returns bigint
language plpgsql stable security definer set search_path = public, app as $$
begin
  return nullif(app.booking_balance_open(p_booking), 0);
exception when others then return null;
end $$;

-- ================================================================ 5. bulk assignment
-- a staff member who can take leads: active, fully onboarded, Sales (not an Admin, not a test account, not blocked from credit)
create or replace function app.lead_assignee_ok(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is not null and exists (select 1 from users u where u.id = p_user and u.status = 'active')
     and not coalesce(app.user_is_admin(p_user), false) and not app.staff_is_test(p_user)
     and app.user_va_has(p_user, 'sales') and app.staff_fully_onboarded(p_user) and not app.credit_blocked(p_user)
$$;

create or replace function app.lead_assignees() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'name', app.sl_name(u.id)) order by app.sl_name(u.id)), '[]'::jsonb)
    from users u where u.status = 'active' and app.lead_assignee_ok(u.id)
$$;

-- the open leads chosen (ids) or matching the filter, oldest first. filter: status (open, new, unclaimed, claimed, contacted),
-- source, type, age (created in the last N days), before_today, assigned (none or a person), q.
create or replace function app.lead_bulk_targets(p jsonb) returns setof uuid
language sql stable security definer set search_path = public, app as $$
  with f as (select coalesce(p -> 'filter', '{}'::jsonb) f, regexp_replace(coalesce(p -> 'filter' ->> 'q', ''), '\D', '', 'g') digits,
                    nullif(lower(btrim(coalesce(p -> 'filter' ->> 'q', ''))), '') q)
  select l.id from leads l, f
   where l.handled_at is null and l.status in ('new', 'contacted', 'qualified') and coalesce(l.sales_outcome, '') not in ('won', 'lost') and app.sl_listed(l)
     and (jsonb_typeof(p -> 'ids') is distinct from 'array' or l.id::text in (select jsonb_array_elements_text(p -> 'ids')))
     and (nullif(f.f ->> 'type', '') is null or app.sl_type(l) = f.f ->> 'type')
     and (nullif(f.f ->> 'source', '') is null or app.sl_source(l) = f.f ->> 'source')
     and (nullif(f.f ->> 'age', '') is null or l.created_at > now() - make_interval(days => (f.f ->> 'age')::int))
     and (not coalesce((f.f ->> 'before_today')::boolean, false) or l.created_at < (date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto'))
     and (nullif(f.f ->> 'assigned', '') is null or (f.f ->> 'assigned' = 'none' and l.assigned_to is null) or l.assigned_to::text = f.f ->> 'assigned')
     and (f.q is null or lower(concat_ws(' ', l.name, l.email, l.message, l.vehicle_text)) like '%' || f.q || '%'
          or (length(f.digits) >= 4 and regexp_replace(coalesce(app.sl_phone(l), ''), '\D', '', 'g') like '%' || f.digits || '%'))
     and case coalesce(nullif(f.f ->> 'status', ''), 'open')
           when 'open' then true
           when 'all' then true
           when 'new' then l.status = 'new' and l.first_contact_at is null
           when 'unclaimed' then not exists (select 1 from lead_claims c where c.lead_id = l.id and c.expires_at > now())
                             and not exists (select 1 from lead_holds h where h.lead_id = l.id and h.expires_at > now())
           when 'claimed' then exists (select 1 from lead_claims c where c.lead_id = l.id and c.expires_at > now())
                            or exists (select 1 from lead_holds h where h.lead_id = l.id and h.expires_at > now())
           when 'contacted' then l.first_contact_at is not null
           else false end
   order by l.created_at, l.id
$$;

-- p: {ids: [...] | filter: {...}, to: user | pool: true, preview: true}. Admin only, at most 500 leads a call (left: how many
-- more match; press again).
create or replace function app.leads_bulk_assign(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c_cap constant integer := 500;
  v_pool boolean := coalesce((p ->> 'pool')::boolean, false);
  v_to uuid := nullif(p ->> 'to', '')::uuid;
  v_ids uuid[];
  v_total integer;
  v_done integer := 0;
  v_same integer := 0;
  x uuid;
  l leads;
  c lead_claims;
begin
  perform app.assert_admin(p_by);
  if jsonb_typeof(p -> 'ids') = 'array' then
    if jsonb_array_length(p -> 'ids') = 0 then raise exception 'Choose at least one lead' using errcode = '22023'; end if;
    if jsonb_array_length(p -> 'ids') > c_cap then raise exception 'At most % leads at once: choose fewer, or use the filter', c_cap using errcode = '22023'; end if;
  elsif jsonb_typeof(p -> 'filter') is distinct from 'object' then
    raise exception 'Choose the leads, or a filter' using errcode = '22023';
  end if;
  if not v_pool then
    if v_to is null then raise exception 'Choose who gets the leads, or Return to the pool' using errcode = '22023'; end if;
    if not app.lead_assignee_ok(v_to) then
      raise exception '% cannot take leads: choose an active, fully onboarded Sales person', coalesce(app.sl_name(v_to), 'That person') using errcode = '22023';
    end if;
  end if;
  perform app.sl_expire();
  v_ids := array(select app.lead_bulk_targets(p));
  v_total := cardinality(v_ids);
  if coalesce((p ->> 'preview')::boolean, false) then
    return jsonb_build_object('preview', true, 'matched', v_total, 'cap', c_cap);
  end if;
  v_ids := v_ids[1:c_cap];
  perform set_config('app.lead_bulk_assign', 'on', true);
  perform set_config('app.lead_admin_move', 'on', true);
  foreach x in array v_ids loop
    select * into l from leads where id = x for update;
    if v_pool then
      select * into c from lead_claims where lead_id = l.id;
      if l.assigned_to is null and c.lead_id is null then v_same := v_same + 1; continue; end if;
      delete from lead_claims where lead_id = l.id;
      insert into lead_claim_log (lead_id, user_id, action, by_user, note)
      values (l.id, coalesce(c.claimed_by, l.assigned_to), 'release', p_by, 'Returned to the pool by an Admin (bulk)');
      update leads set assigned_to = null, admin_assigned_by = null, admin_assigned_at = null, updated_at = now() where id = l.id;
    else
      if l.assigned_to = v_to and l.admin_assigned_at is not null then v_same := v_same + 1; continue; end if;
      select * into c from lead_claims where lead_id = l.id and claimed_by <> v_to;
      if c.lead_id is not null then
        delete from lead_claims where lead_id = l.id;
        insert into lead_claim_log (lead_id, user_id, action, by_user, note)
        values (l.id, c.claimed_by, 'release', p_by, left('Assigned to ' || app.sl_name(v_to) || ' by an Admin', 300));
      end if;
      update leads set assigned_to = v_to, admin_assigned_by = p_by, admin_assigned_at = now(), updated_at = now() where id = l.id;
      insert into lead_claim_log (lead_id, user_id, action, by_user, note) values (l.id, v_to, 'assign', p_by, 'Assigned by an Admin (bulk)');
    end if;
    v_done := v_done + 1;
  end loop;
  perform set_config('app.lead_bulk_assign', '', true);
  perform set_config('app.lead_admin_move', '', true);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'leads_bulk_assign', 'leads', null, jsonb_build_object('to', v_to, 'to_name', case when v_to is not null then app.sl_name(v_to) end, 'pool', v_pool,
          'filter', p -> 'filter', 'chosen', jsonb_typeof(p -> 'ids') = 'array', 'changed', v_done, 'unchanged', v_same,
          'left', greatest(v_total - c_cap, 0), 'leads', to_jsonb(v_ids)));
  return jsonb_build_object('matched', v_total, 'changed', v_done, 'unchanged', v_same, 'left', greatest(v_total - c_cap, 0), 'cap', c_cap,
    'to', v_to, 'to_name', case when v_to is not null then app.sl_name(v_to) end, 'pool', v_pool);
end $$;

-- an Admin's assignment ends when the lead moves to someone else by any other path
create or replace function app.leads_admin_assign_clear() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.assigned_to is distinct from old.assigned_to and coalesce(current_setting('app.lead_bulk_assign', true), '') <> 'on' then
    new.admin_assigned_by := null;
    new.admin_assigned_at := null;
  end if;
  return new;
end $$;
create trigger leads_admin_assign_clear before update of assigned_to on leads for each row execute function app.leads_admin_assign_clear();

-- nobody else claims a lead an Admin assigned (an Admin's own move, a reassign or a return, still may)
create or replace function app.lead_claims_admin_assigned() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare l leads;
begin
  select * into l from leads where id = new.lead_id;
  if l.admin_assigned_at is null or l.assigned_to is null or l.assigned_to = new.claimed_by then return new; end if;
  if coalesce(current_setting('app.lead_admin_move', true), '') = 'on' or coalesce(app.user_is_admin(new.claimed_by), false) then return new; end if;
  raise exception 'An Admin assigned this lead to %. Ask an Admin to reassign it.', app.sl_name(l.assigned_to) using errcode = '23514';
end $$;
create trigger lead_claims_admin_assigned before insert or update of claimed_by on lead_claims for each row execute function app.lead_claims_admin_assigned();

-- the assignee's claims on their assigned leads are not paced or capped
select pg_temp.patch_fn('app.lead_claims_paced()'::regprocedure,
  'if TG_OP = ''UPDATE'' and new.claimed_by = old.claimed_by then return new; end if;',
  'if TG_OP = ''UPDATE'' and new.claimed_by = old.claimed_by then return new; end if;
  if exists (select 1 from leads x where x.id = new.lead_id and x.assigned_to = new.claimed_by and x.admin_assigned_at is not null) then return new; end if;');
select pg_temp.patch_fn('app.lead_claim(uuid, jsonb)'::regprocedure,
  'if n >= app.sl_cap_n(p_by) then raise exception',
  'if n >= app.sl_cap_n(p_by) and not coalesce(l.assigned_to = p_by and l.admin_assigned_at is not null, false) then raise exception');
-- Next lead skips a lead an Admin assigned to someone else
select pg_temp.patch_fn('app.sl_open_pool(uuid, text, timestamptz)'::regprocedure,
  'and l.created_at > p_now - interval ''90 days''',
  'and l.created_at > p_now - interval ''90 days''
     and (l.admin_assigned_at is null or l.assigned_to is null or l.assigned_to = p_by)');
-- a call hold over an assigned lead gives it back to the assignee
select pg_temp.patch_fn('app.lead_hold_end(uuid, uuid, text, boolean, timestamptz)'::regprocedure,
  'v_to := h.prev_claimed_by;',
  'v_to := case when l.admin_assigned_at is not null and l.assigned_to is not null then l.assigned_to else h.prev_claimed_by end;');

-- each row says whether its assignment is an Admin's
alter function app.sl_row(leads, uuid) rename to sl_row_pre2411;
create function app.sl_row(l leads, p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.sl_row_pre2411(l, p_by) || jsonb_build_object('admin_assigned', l.admin_assigned_at is not null and l.assigned_to is not null)
$$;
select pg_temp.copy_grants('app.sl_row(leads, uuid)'::regprocedure, 'app.sl_row_pre2411(leads, uuid)'::regprocedure);

-- the Admin's list carries who can take leads (the Assign to choices)
alter function app.sales_leads(uuid, jsonb) rename to sales_leads_pre2411;
create function app.sales_leads(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := app.sales_leads_pre2411(p_by, p);
begin
  return v || jsonb_build_object('assignees', case when coalesce(app.user_is_admin(p_by), false) then app.lead_assignees() else '[]'::jsonb end);
end $$;
select pg_temp.copy_grants('app.sales_leads(uuid, jsonb)'::regprocedure, 'app.sales_leads_pre2411(uuid, jsonb)'::regprocedure);

-- ================================================================ 6. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2411;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call in ('ops_read', 'va_read', 'admin_read') and p_name = 'lead_context') or (p_call in ('ops_do', 'admin_do') and p_name = 'leads_bulk_assign') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    p := coalesce(p, '{}'::jsonb) - '_va';
    return case p_name when 'lead_context' then app.lead_context(p_user, p) else app.leads_bulk_assign(p_user, p) end;
  end if;
  return app.door_pre2411(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2411(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 7. privileges
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['person_keys', 'pk_uuids', 'pk_texts', 'person_sessions', 'person_phone', 'person_behaviour', 'person_signals',
             'intent_inputs', 'intent_score_pre2411', 'person_handled_by', 'lead_context', 'lead_context_open', 'lead_assignee_ok', 'lead_assignees', 'lead_bulk_targets',
             'leads_bulk_assign', 'leads_admin_assign_clear', 'lead_claims_admin_assigned', 'sl_row_pre2411', 'sales_leads_pre2411', 'door_pre2411'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- GUIDES 2411 START (generated by supabase/seed/2411_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('admin', 'leads-and-sales-claims', 'chapter', 'text-alerts-email-text-or-both', 'Every lead in one place: people who are not renters or owners yet, from every source, with who is working on each one. Open **People** > **Renters** > **All leads**. An alert for a new lead (in the app, on the phone, or by email) opens that lead''s own page.

## What is in the list

- **Renter leads**: the contact form, live chat, the phone number box, discount game claims, offers that expired, booking requests typed and not sent, calls missed from a number with no booking (they arrive by themselves within 15 minutes), and Live visitors who turned Hot and left an email.
- **Owner leads**: owner program enquiries, owner applications started and not finished, owner form contacts and earnings calculator contacts. They are also under **People** > **Owners** > **Leads**, and each New owner program enquiry task opens its lead.
- **Partner leads**: fleet suppliers, dealers, rental businesses and insurers.

Each card shows the name, phone, email, the source in plain words (a live chat lead says Live chat), how old it is, and the start of what they wrote. New and hot leads come first. Open a lead for everything they wrote, the live chat transcript, their calls, every contact logged and the claim history.

## Work a lead

1. Press **Claim** on a card, or **Next lead** for the oldest hot lead nobody holds. It is yours for 15 minutes; nobody else can work on it meanwhile.
2. Press **Call**, **Text** or **Email**. Your phone or mail app opens and the contact is logged on the lead. Each call, text, email or **Note** adds another 15 minutes to your claim, up to 60 minutes from when you claimed it.
3. Press **Outcome** and choose Contacted, Call booked, Applied, Won (with the booking number when there is one) or Lost (say why). Won and lost close the lead.
4. Nothing more to do? Press **Mark handled**. Done with it for now? Press **Unclaim**: it goes back to the pool at once.

A claim that runs out returns the lead to the pool for everyone. One person holds at most 25 leads at a time. When a renter lead''s person books and the booking is confirmed, the lead closes as Won by itself, for the Sales person on the booking.

## As an Admin

- **Reassign** gives a lead to a person (their claim, and the lead is assigned to them). **Release** ends someone''s claim.
- **Sales team** shows each person''s leads claimed, won, close rate (won out of claimed), contacted, time to first contact and claims that ran out, today, this week or this month, best first.
- **Settings** > **Sales** sets how long a claim holds for renter, owner and partner leads (10 to 15 minutes suggested), the most a claim can be extended to, how many leads one person may hold, and how long a lead counts as hot.

> Good to know: Filters narrow the list by type, source, status, age, person and your own leads; the search finds a name, phone number, email or words they wrote.

## Rebooking, intent and leads (release 35)

- A returning renter''s new request goes straight to the salesperson of their last booking, with the usual claim time.
- Every renter and lead has an intent score (hot, warm or cold) with what they said they want: budget, car class, length, dates, urgency, delivery and coverage, read from calls (with their transcripts), texts, emails, the site chat and their visits.
- Leads are never given out by themselves: onboarded Sales claim them, one every 5 minutes, up to 3 open at once plus one for every 5 won in the last 30 days (at most 10).

## Leads handled on a call by customer service or Fleet (release 37)

A lead that customer service or Fleet handle on a call (they answer or place the call, add a note, or create the lead from the call) is held for them for **Customer service and Fleet: a lead they handle on a call is held for** minutes in **Settings** > **Sales** (empty: the Sales claim minutes of its type). Each new handled call adds the time. Sales see **Being handled by** and cannot work it; **Next lead** skips it. **Release hold** on the lead ends it at once; it returns to the salesperson who had a claim on it or brought it, else the open list. Your own reassign also ends it. A booking made from the lead keeps the usual credit; the hold is not a claim, so customer service is never credited. Every step is in the lead''s history (hold, another call handled, hold ended).', 'Leads and Sales claims', 'Every lead in one place, claims, outcomes and the Sales team''s numbers.',
  'Every lead in one place: people who are not renters or owners yet, from every source, with who is working on each one. Open **People** > **Renters** > **All leads**. An alert for a new lead (in the app, on the phone, or by email) opens that lead''s own page.

## What is in the list

- **Renter leads**: the contact form, live chat, the phone number box, discount game claims, offers that expired, booking requests typed and not sent, calls missed from a number with no booking (they arrive by themselves within 15 minutes), and Live visitors who turned Hot and left an email.
- **Owner leads**: owner program enquiries, owner applications started and not finished, owner form contacts and earnings calculator contacts. They are also under **People** > **Owners** > **Leads**, and each New owner program enquiry task opens its lead.
- **Partner leads**: fleet suppliers, dealers, rental businesses and insurers.

Each card shows the name, phone, email, the source in plain words (a live chat lead says Live chat), how old it is, and the start of what they wrote. New and hot leads come first. Open a lead for everything they wrote, the live chat transcript, their calls, every contact logged and the claim history.

## Work a lead

1. Press **Claim** on a card, or **Next lead** for the oldest hot lead nobody holds. It is yours for 15 minutes; nobody else can work on it meanwhile.
2. Press **Call**, **Text** or **Email**. Your phone or mail app opens and the contact is logged on the lead. Each call, text, email or **Note** adds another 15 minutes to your claim, up to 60 minutes from when you claimed it.
3. Press **Outcome** and choose Contacted, Call booked, Applied, Won (with the booking number when there is one) or Lost (say why). Won and lost close the lead.
4. Nothing more to do? Press **Mark handled**. Done with it for now? Press **Unclaim**: it goes back to the pool at once.

A claim that runs out returns the lead to the pool for everyone. One person holds at most 25 leads at a time. When a renter lead''s person books and the booking is confirmed, the lead closes as Won by itself, for the Sales person on the booking.

## As an Admin

- **Reassign** gives a lead to a person (their claim, and the lead is assigned to them). **Release** ends someone''s claim.
- **Sales team** shows each person''s leads claimed, won, close rate (won out of claimed), contacted, time to first contact and claims that ran out, today, this week or this month, best first.
- **Settings** > **Sales** sets how long a claim holds for renter, owner and partner leads (10 to 15 minutes suggested), the most a claim can be extended to, how many leads one person may hold, and how long a lead counts as hot.

> Good to know: Filters narrow the list by type, source, status, age, person and your own leads; the search finds a name, phone number, email or words they wrote.

## Rebooking, intent and leads (release 35)

- A returning renter''s new request goes straight to the salesperson of their last booking, with the usual claim time.
- Every renter and lead has an intent score (hot, warm or cold) with what they said they want: budget, car class, length, dates, urgency, delivery and coverage, read from calls (with their transcripts), texts, emails, the site chat and their visits.
- Leads are never given out by themselves: onboarded Sales claim them, one every 5 minutes, up to 3 open at once plus one for every 5 won in the last 30 days (at most 10).

## Leads handled on a call by customer service or Fleet (release 37)

A lead that customer service or Fleet handle on a call (they answer or place the call, add a note, or create the lead from the call) is held for them for **Customer service and Fleet: a lead they handle on a call is held for** minutes in **Settings** > **Sales** (empty: the Sales claim minutes of its type). Each new handled call adds the time. Sales see **Being handled by** and cannot work it; **Next lead** skips it. **Release hold** on the lead ends it at once; it returns to the salesperson who had a claim on it or brought it, else the open list. Your own reassign also ends it. A booking made from the lead keeps the usual credit; the hold is not a claim, so customer service is never credited. Every step is in the lead''s history (hold, another call handled, hold ended).

## The person behind the lead, and assigning leads in bulk (release 40)

**The person.** Open a lead, or press **The person** on its card, to see everything we know about whoever sent it, matched by their renter record, email and phone: their name and the name they go by, phone and email, whether they have an account and whether their licence is verified (yes or no; the number is never shown), every booking (car, dates, status, total and any open balance), what they owe and their deposit, open requests and offers sent, their earlier leads, their messages, calls and texts, notes, reviews, incidents and claims, and who has handled them (Helped by, and who claimed, held or was assigned their leads).

**Signals.** The intent score and the **Signals** timeline are for the whole person, not one lead: calls (in, out, missed, with their length), texts both ways, WhatsApp, Messenger and Instagram messages, the site chat, emails they wrote, links they opened in our emails, visits and cars looked at, offers, quotes and payment pages opened, bookings, rentals, cancellations and reviews. Newest first.

**Assign in bulk.** On **Leads**, tick cards (or **Select all on this page**), or choose **Everything the filter matches** to take every open lead the filters show (status, type, source, age, person, words). Choose a Sales person in **Assign to**, or **Return to the pool**, and press **Assign**: you see how many leads match and confirm first. **Assign every unassigned lead older than today** takes every open lead nobody has (no person, no claim, no hold) that came in before today, after the same confirm. Up to 500 leads go per press; when more match, it says how many are left: press again.

- Only active, fully onboarded Sales staff can be chosen. Customer service, Fleet and Finance take no sales credit, so they are not in the list.
- A bulk assignment is your assignment, not a claim: it does not run out, nobody else can claim the lead, and **Next lead** skips it for everyone else. The person''s claims on their assigned leads do not count against their limits.
- A customer service or Fleet call can still hold the lead while they handle it; when the hold ends, the lead goes back to the assigned person.
- **Reassign** on one lead still gives a timed claim, as before. **Return to the pool** ends the assignment and any claim.
- Every lead moved shows **Assigned by an Admin to** in its history, and each press is one entry in the audit log.',
  '<p class="gd-p">Every lead in one place: people who are not renters or owners yet, from every source, with who is working on each one. Open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Renters</b> &gt; <b class="gd-ui">All leads</b>. An alert for a new lead (in the app, on the phone, or by email) opens that lead&#39;s own page.</p><section class="gd-task" id="leads-and-sales-claims-what-is-in-the-list" data-gd-task><h2 class="gd-h2">What is in the list</h2><ul class="gd-ul"><li><b class="gd-ui">Renter leads</b>: the contact form, live chat, the phone number box, discount game claims, offers that expired, booking requests typed and not sent, calls missed from a number with no booking (they arrive by themselves within 15 minutes), and Live visitors who turned Hot and left an email.</li><li><b class="gd-ui">Owner leads</b>: owner program enquiries, owner applications started and not finished, owner form contacts and earnings calculator contacts. They are also under <b class="gd-ui">People</b> &gt; <b class="gd-ui">Owners</b> &gt; <b class="gd-ui">Leads</b>, and each New owner program enquiry task opens its lead.</li><li><b class="gd-ui">Partner leads</b>: fleet suppliers, dealers, rental businesses and insurers.</li></ul><p class="gd-p">Each card shows the name, phone, email, the source in plain words (a live chat lead says Live chat), how old it is, and the start of what they wrote. New and hot leads come first. Open a lead for everything they wrote, the live chat transcript, their calls, every contact logged and the claim history.</p></section><section class="gd-task" id="leads-and-sales-claims-work-a-lead" data-gd-task><h2 class="gd-h2">Work a lead</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Claim</b> on a card, or <b class="gd-ui">Next lead</b> for the oldest hot lead nobody holds. It is yours for 15 minutes; nobody else can work on it meanwhile.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Call</b>, <b class="gd-ui">Text</b> or <b class="gd-ui">Email</b>. Your phone or mail app opens and the contact is logged on the lead. Each call, text, email or <b class="gd-ui">Note</b> adds another 15 minutes to your claim, up to 60 minutes from when you claimed it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Outcome</b> and choose Contacted, Call booked, Applied, Won (with the booking number when there is one) or Lost (say why). Won and lost close the lead.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Nothing more to do? Press <b class="gd-ui">Mark handled</b>. Done with it for now? Press <b class="gd-ui">Unclaim</b>: it goes back to the pool at once.</div></li></ol></div><p class="gd-p">A claim that runs out returns the lead to the pool for everyone. One person holds at most 25 leads at a time. When a renter lead&#39;s person books and the booking is confirmed, the lead closes as Won by itself, for the Sales person on the booking.</p></section><section class="gd-task" id="leads-and-sales-claims-as-an-admin" data-gd-task><h2 class="gd-h2">As an Admin</h2><ul class="gd-ul"><li><b class="gd-ui">Reassign</b> gives a lead to a person (their claim, and the lead is assigned to them). <b class="gd-ui">Release</b> ends someone&#39;s claim.</li><li><b class="gd-ui">Sales team</b> shows each person&#39;s leads claimed, won, close rate (won out of claimed), contacted, time to first contact and claims that ran out, today, this week or this month, best first.</li><li><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Sales</b> sets how long a claim holds for renter, owner and partner leads (10 to 15 minutes suggested), the most a claim can be extended to, how many leads one person may hold, and how long a lead counts as hot.</li></ul><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Filters narrow the list by type, source, status, age, person and your own leads; the search finds a name, phone number, email or words they wrote.</div></aside></section><section class="gd-task" id="leads-and-sales-claims-rebooking-intent-and-leads-release-35" data-gd-task><h2 class="gd-h2">Rebooking, intent and leads (release 35)</h2><ul class="gd-ul"><li>A returning renter&#39;s new request goes straight to the salesperson of their last booking, with the usual claim time.</li><li>Every renter and lead has an intent score (hot, warm or cold) with what they said they want: budget, car class, length, dates, urgency, delivery and coverage, read from calls (with their transcripts), texts, emails, the site chat and their visits.</li><li>Leads are never given out by themselves: onboarded Sales claim them, one every 5 minutes, up to 3 open at once plus one for every 5 won in the last 30 days (at most 10).</li></ul></section><section class="gd-task" id="leads-and-sales-claims-leads-handled-on-a-call-by-customer-service-or-fleet-release" data-gd-task><h2 class="gd-h2">Leads handled on a call by customer service or Fleet (release 37)</h2><p class="gd-p">A lead that customer service or Fleet handle on a call (they answer or place the call, add a note, or create the lead from the call) is held for them for <b class="gd-ui">Customer service and Fleet: a lead they handle on a call is held for</b> minutes in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Sales</b> (empty: the Sales claim minutes of its type). Each new handled call adds the time. Sales see <b class="gd-ui">Being handled by</b> and cannot work it; <b class="gd-ui">Next lead</b> skips it. <b class="gd-ui">Release hold</b> on the lead ends it at once; it returns to the salesperson who had a claim on it or brought it, else the open list. Your own reassign also ends it. A booking made from the lead keeps the usual credit; the hold is not a claim, so customer service is never credited. Every step is in the lead&#39;s history (hold, another call handled, hold ended).</p></section><section class="gd-task" id="leads-and-sales-claims-the-person-behind-the-lead-and-assigning-leads-in-bulk-relea" data-gd-task><h2 class="gd-h2">The person behind the lead, and assigning leads in bulk (release 40)</h2><p class="gd-p"><b class="gd-ui">The person.</b> Open a lead, or press <b class="gd-ui">The person</b> on its card, to see everything we know about whoever sent it, matched by their renter record, email and phone: their name and the name they go by, phone and email, whether they have an account and whether their licence is verified (yes or no; the number is never shown), every booking (car, dates, status, total and any open balance), what they owe and their deposit, open requests and offers sent, their earlier leads, their messages, calls and texts, notes, reviews, incidents and claims, and who has handled them (Helped by, and who claimed, held or was assigned their leads).</p><p class="gd-p"><b class="gd-ui">Signals.</b> The intent score and the <b class="gd-ui">Signals</b> timeline are for the whole person, not one lead: calls (in, out, missed, with their length), texts both ways, WhatsApp, Messenger and Instagram messages, the site chat, emails they wrote, links they opened in our emails, visits and cars looked at, offers, quotes and payment pages opened, bookings, rentals, cancellations and reviews. Newest first.</p><p class="gd-p"><b class="gd-ui">Assign in bulk.</b> On <b class="gd-ui">Leads</b>, tick cards (or <b class="gd-ui">Select all on this page</b>), or choose <b class="gd-ui">Everything the filter matches</b> to take every open lead the filters show (status, type, source, age, person, words). Choose a Sales person in <b class="gd-ui">Assign to</b>, or <b class="gd-ui">Return to the pool</b>, and press <b class="gd-ui">Assign</b>: you see how many leads match and confirm first. <b class="gd-ui">Assign every unassigned lead older than today</b> takes every open lead nobody has (no person, no claim, no hold) that came in before today, after the same confirm. Up to 500 leads go per press; when more match, it says how many are left: press again.</p><ul class="gd-ul"><li>Only active, fully onboarded Sales staff can be chosen. Customer service, Fleet and Finance take no sales credit, so they are not in the list.</li><li>A bulk assignment is your assignment, not a claim: it does not run out, nobody else can claim the lead, and <b class="gd-ui">Next lead</b> skips it for everyone else. The person&#39;s claims on their assigned leads do not count against their limits.</li><li>A customer service or Fleet call can still hold the lead while they handle it; when the hold ends, the lead goes back to the assigned person.</li><li><b class="gd-ui">Reassign</b> on one lead still gives a timed claim, as before. <b class="gd-ui">Return to the pool</b> ends the assignment and any claim.</li><li>Every lead moved shows <b class="gd-ui">Assigned by an Admin to</b> in its history, and each press is one entry in the audit log.</li></ul></section>');
select app.guide_release_section('va', 'customer-service', 'chapter', 'your-workday', 'You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter''s first person. There is no commission for customer service, but your help is credited on the booking (Helped by) and on your scorecard.

Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.

## Answer a request

1. Open **Requests and offers**: one queue (the numbers at the top are filters; **Active** always shows everything), the most urgent first, with how long each renter has waited, the countdown to the 2 hours the site promises, the car''s photo, the renter with **Call** and **Text**, the licence and one button (**Send offer**, **Follow up** or **Open**). Filter by Active, New, Asked the renter, Changes asked, Offer out, Not paid or Expired; an expired offer moves to Expired after 48 hours.
2. Waiting shows how long the renter has waited. Open the booking number.

![](/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg "desktop; size: 1440 640; address: carmacars.ca/va/requests; pins: 1 27.1 17.5, 2 52.8 32.8")

3. On the Review tab, check the request: the car is free, the renter, the places.
4. Press **Adjust the booking** to change the car, dates, places, price or extras, then **Save changes**.
5. Add a message and press **Send the offer**. Within your limit you can also use **Approve (within my limit)** or **Approve and send the pay link**.
6. Can''t do it? **Decline** with Reason and any alternative. Need to know more? **Ask the renter**.

![](/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg "desktop; size: 1440 1000; address: carmacars.ca/va/bookings/CC-10069?tab=review; pins: 3 69.4 24.0, 4 95.8 98.0")

> Tip: Reply within 5 minutes: send the offer, or ask the renter what you need. That is the "First reply in opening hours" measure on your scorecard. Requests waiting longer show in red.

Opening a request takes it for you: the others see "Being answered by" your name and cannot answer it until you send, decline or leave (20 minutes, renewed while you work). One someone else holds shows who, with the buttons off; it opens to you when their claim runs out, or ask an Admin to take it over. Sales: a request from the website shows "Opens to you at" a time for its first 15 minutes, and a To do task says when it opens; after that whoever opens it first answers it, customer service included.

## An enquiry on an example car

Some cars on the site are marked "Example car": samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.

1. The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact. When a real car was free for those dates, the task names it after **Free:** (the same make and model first, else the same class and body at a similar price), and the person was told we have a similar car and will confirm it within 2 hours.
2. Check the named car is still right for them (or find a real car of the same kind and price that is free for those dates), and make a **New quote** for it.
3. Call or email the person with the car and the price, then mark the task done.

> Tip: Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.

## A request from a vehicle page

Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.

1. The request arrives as an enquiry with the car named in the message ("About the car: 2023 Toyota RAV4 XLE") and an Enquiry task in To do.
2. If we have that car, or one close to it, free for their dates, make a **New quote** for it. If not, suggest the nearest car of the same kind and price.
3. Reply by email or phone, then mark the task done.

> Tip: The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.

## A buyer lead from a /buy page

Every vehicle page has a for-sale twin (carmacars.ca/buy/toyota/rav4/2023/xle) with "Find me this car", and twins for financing, detailing and body shop work with their own request: a name, an email or phone, and when.

1. The lead is in **Buyer leads** (customer service: **Owners and enquiries**), Buyer leads (kind buyer, finance, detailing or body shop), with the car and what they asked, and a To do line for Sales: A buyer asked us to find a car, Someone asked about financing or leasing a car, A detailing request, or A body shop request.
2. If one of our cars of that kind is for sale (an Admin flags it with its price), offer it. If not, offer to rent them the car for a week first, and say what we can find. We do not lend or lease: on a financing question, say so and offer the rental. For detailing or body shop work, give a time and a price, and always offer a rental while their car is in (an insurance replacement rental when it is a claim). For mechanical work (a "Mechanical work to arrange" task: an oil change, brakes, tires, a tow and the like), CarmaCars does not do the work: book it with a trusted shop or recommend one, never promise the shop''s price or time, and offer a rental while their car is in.
3. Press **Take it**, then **Update** as you go: contacted, qualified, converted or closed with the reason.

> Tip: We mostly rent cars. Never say a car is for sale unless an Admin flagged it; the page shows it with its price when one is.

## Send an offer to a caller

Open **Send an offer** (or **Send an offer** beside a car in Find a car). No request needed: one screen, and the renter has the link.

1. Find the customer by name, phone or email, or press **Add a new customer**: full legal name, mobile, email and date of birth. Already on file with that email or phone? Use them: never a second record.
2. Choose the car (by car code, plate or name; each says Free or Not free), the dates and the places.
3. The price: the rate sheet, a total or a rate per day, with the reason for a price you type. The deposit, discounts and fees are set by an Admin; customer service sets the Protection Plan price. Amounts I type, at the top of the price: Before tax, or After tax (HST included) to type what the renter pays, worked back to before tax for you. Or type the Total the renter pays (after tax): the rental charge is worked out from it.
4. How the rental and the deposit are paid (card online, e-Transfer, cash, platform payout, the insurer; deposit by card hold, cash or e-Transfer), who found this client, the message, how long it is open (48 hours at most) and Email, Text or both.
5. Check the offer as the renter will see it on the right, then press **Send the offer**.

> Tip: An offer that is out is changed in place: **More actions** > **Edit the offer**, change it, then **Save and send the update** or **Save without telling the renter**. No need to withdraw it first.

## New quote for a caller

1. Open **New quote**. Choose the Car, the Pickup and Return (at least 2 hours from now).
2. Choose how the lead came in, then the caller''s Full legal name, Email, Mobile and Date of birth.
3. Set the Licence class and Damage cover, and note places, extras and what they asked.
4. Press **Create the request**. It opens like any request; send the offer from there.

![](/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg "desktop; size: 1220 1260; address: carmacars.ca/va/quotes/new; pins: 1 72.1 15.6, 2 72.1 41.7, 3 72.1 72.7, 4 63.9 85.5")

## Edit a booking, a fee or the renter

A booking that is confirmed, on trip or returned is edited directly; the renter''s details are corrected from the booking.

1. Overview, **Edit the booking**: the return (extend or shorten), the car, the rental charge, each fee, the kilometres and the note. Tick **Email the renter what changed**, or leave it off for a silent correction.
2. Money tab, Fees, **Change or add a fee**: a fee forgotten (the young driver fee shows its price for the dates) or a charge of its own.
3. What is open shows at once: **Email a pay link** or **Text a pay link** for exactly that amount, or record cash or an e-Transfer (Rental charges, Collect (the amount) rental, **Cash, e-Transfer or another way (record it)**).
4. **Edit renter**: a wrong email, phone, name, licence or address. A new email is their sign-in at once.
5. The same renter twice? Under the renter, Possible duplicates: **Merge into this record** moves everything of the other record here.

> Good to know: Each edit is recorded with your name, the time, the reason and the before and after.

## Renter messages and Find a renter

1. **Renter messages** lists the latest messages with their booking. Open the booking to reply, then press **Send**.
2. **Find a renter**: search by name, email, phone or booking number.
3. To open a renter''s private details, press **Open with a reason**. The reason is kept in the access log.

![](/guides/img/va-cs-06-messages-desktop-3441fa91.jpg "desktop; size: 1440 260; address: carmacars.ca/va/messages; pins: 1 32.6 48.5")

## Add a car for an owner

Open **Owners** > **Add a car for an owner** (fleet: under Cars). You enter everything for the owner; they never fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN. The car is looked up at once and shown in one line with the year, make, model, trim and details (Edit if something is wrong). No VIN at hand: add it by its plate and choose the year, make and model. Tap the colour and check the class. Upload the ownership permit, the insurance slip and the lender''s information if you have them. Photos are optional.
3. Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner. The owner signs in the owner portal after one email (no paper signature).
5. Press **Add the car and send to an Admin**. The application waits in the Admin''s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.

> Good to know: A fleet supplier (a corporation leasing its cars to CarmaCars): choose New owner, **A corporation**, then Route **Fleet supplier: leases the cars to CarmaCars**. The default lease terms are set at once. For the car, enter the VIN, the plate and the ownership copy, choose its tier, **Regular** or **Troubled** (it is set once), and who it is registered to now (for a car moving in or bought, the name and address on the ownership and the date). Its ServiceOntario forms are filled in at once. No terms, no invoices and no paper signing: the supplier signs in the owner portal. The car goes on the lease when an Admin approves it.

## Owners: the checklist, the photos and the forms (release 34)

Open **Owners** (customer service and fleet), then an owner. Search finds any owner by name, email, plate or VIN.

1. The **Onboarding checklist**: per car, each step done, to do (and who it waits on), blocked (and why) or not needed, with the one button to press.
2. **Onboarding photos**: **Replace** or **Remove** (with a reason) a wrong ownership permit, insurance slip or lender''s letter, or **Approve** or mark it **Not accepted** (the owner reads why). A replaced photo is checked again.
3. **Government forms**: each ServiceOntario form the car needs, made by themselves, with its status, the date it was made and its download.
4. **Add cars from a list of VINs** for the owner: paste or upload, **Preview**, **Add**.

## Owner forms (Forms C and D)

1. Open **Owner forms**. Each row is a scan an owner uploaded before November 2026 (Forms C and D are signed on screen since then), with the witnesses and the status.
2. Press Open to read the scan. Check every page is there and signed, with each witness''s signature and name.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg "desktop; size: 1440 300; address: carmacars.ca/va/owner-forms; pins: 2 68.6 36.7, 3 76.7 36.7")

## Rental agreements are signed online only

A rental agreement, or a booking change, is signed by the renter in their portal or on the phone at the handover (the e-signature). A copy signed on paper is not accepted or recorded: send the renter the link again from the booking. One recorded before November 2026 stays readable under Signed on paper.

## Signatures on the spot, or by link

A renter or an additional driver who has not signed yet.

1. On the booking, press **Sign now on this device**. Confirm the name and that you saw the original licence, then **Hand the device to** the signer.
2. Or press **Email the signing link** or **Text the signing link**: they sign on their own phone.
3. The licence comes first: the renter uploads it from the request, and the offer cannot be accepted without it.

## The booking''s rental agreements

The Rental agreements card keeps both agreements in step with the booking.

1. Any change after signing makes a new version by itself. A change to the dates, the price, the car, the drivers or the coverage waits for the renter''s signature: they get the link by email and text, and the card says "Agreement v3 waiting for signature".
2. **Resend the signing links**, or press the button with their first name beside it to have them sign on your device.
3. Fields still blank (a licence expiry, an insurer''s policy number) are listed: type them and press **Save the missing fields**. Check-in stops on a field a claim needs until it is filled or an Admin overrides.
4. Every signature: a code to the signer''s phone or email, the key terms initialled, three consents, a drawn signature.

## Check renter documents

The renter''s licence photos, selfie and proof of coverage, before the handover.

1. Open the task "identity documents or coverage proof to review", or open the booking: **Review** shows the documents of any booking being arranged or under way, with no task needed.
2. Every licence image, selfie and proof of coverage of the booking is on one screen, with what to check written once above them: the selfie matches, no alteration, the coverage is active to the return date.
3. Under each driver, the licence reader lists what it read (from the back''s barcode, else the photo) and one line per check, Pass or Flag: photos sharp and whole, valid to the return, class accepted, old enough at pickup, name and date of birth match the driver, the Ontario number, front and back the same licence, and the main driver''s Ontario licence. Look closely at each Flag.
4. One is wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**.
5. Then press **Approve all**: everything still waiting is approved at once (the Protection Plan too). A document the system refuses is named with the reason; the rest are approved.

> Tip: Each opening is logged. An Admin can do the same from Admin > To do. Field staff review the licence images (not the coverage) of bookings on their own jobs in the next 7 days from their My jobs: the booking history says the role, field.

> Good to know: Main driver: Ontario licence needed. When the main driver''s licence is from elsewhere, they are moved to additional driver (their photos and checks stay; you still review them) and pickup is blocked until a driver with an Ontario licence is the main driver. The renter adds one from their booking. Only an Admin can undo the swap or let it go with a reason.

## Which credit cards include rental car coverage?

Renters ask this often. **Renters** > **Card coverage** (every function has it under Rentals or Bookings) is your quick reference: what to say, what to check, and the list.

1. Send the renter `carmacars.ca/credit-card-rental-coverage`: each card''s car value limit (MSRP), longest rental, key exclusions, its official guide and the day we last checked it.
2. Ask which car they want. Most Canadian cards stop at a car priced $65,000 or $85,000, and many luxury models are priced higher. Give them the car''s model year and trim so they can check.
3. Never tell a renter they are covered. Their card''s issuer decides that: ask them to call the number on the back of their card about this car and these dates. CarmaCars does not decide claims.
4. Over the limit, an excluded make, a debit card or a longer rental than the card allows: offer OPCF 27 on their own auto policy or the CarmaCars Protection Plan.

> Tip: A card marked Unverified came from a published summary, not the issuer''s guide. Something wrong or out of date in the list? Tell an Admin: they correct it in Settings > Card coverage.

## Review requests

Renters are asked for a review by email and text after each trip. **Renters** > **Review requests** shows the ones on hold and the Google reviews to match.

1. On hold: the booking has a charge that is not settled or waived yet (late return, kilometres, fuel, cleaning, smoking, damage, tolls) or an open incident. It leaves the list by itself once the charges are settled or waived.
2. The renter should be asked now anyway? Press **Send anyway**. Should never be asked? Press **Do not ask**.
3. Google reviews: a possible match to a renter shows "possible match". Press **Confirm** if it is them, **Not this renter** if not, or **Match to a booking** with the booking number.
4. A review that came another way (Turo, a text, a call, email): press **Add a customer review** and type the customer''s first name and last initial, the source, the date received, the rating and their words exactly as received, with a screenshot if you have one. It shows on the site with its source. Never write or change a review for a customer.
5. On a booking, the card Review requests has **Ask for a review** (for example after a call that went well) and **Mark reviewed** when the renter says they already left one.

> Tip: Never offer anything for a review and never ask only happy renters: everyone gets the same message and the same Google link.

## A change to a confirmed booking

On a booking''s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press **Preview the price**, then **Send to the renter**. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.

## A late return

A booking past its return time shows the late return panel. The renter can still extend in their booking while they have the car: the extension counts from the original return time, it is approved at once when the car is free, and paying it stops the late notices. Point them to **Extend** first. Otherwise work it in order:

| Button | When |
| --- | --- |
| **Log a call** | Record each call to the renter and what they said. |
| **Send T13** | The first late notice email. |
| **Send T14 (final notice)** | The final notice. |
| **Request disable** | Ask an Admin to approve disabling the car. |
| **Open an incident** | When the car is not coming back as planned. |

## Booked when the renter accepts (release 28)

A renter who approves the offer has booked the car, even before paying: the booking shows **Booked, payment due** and holds the car everywhere. Collect the payment before the pickup (a **Booked, payment due** To do comes 48 hours before). When you send an offer, the renter''s view is right under **Send the offer**.

## When a check stops the pickup or the return (release 33)
On the booking page, **What stops the pickup now** (or the return) lists each check that stops it, in plain words. When the trip must go ahead anyway, press **Ask an Admin to override the pickup** (or the return), give the actual time, the km and fuel if you know them, and why. An Admin gets an alert and approves in one tap; the pickup (or the return) is then recorded with the time you entered, and the booking''s history says who asked and who approved. You can cancel your request while it waits. A trip that happened and was never recorded: **Ask to record a past trip** with both times; once an Admin approves, the booking lands in Returned so the deposit can be settled.

## Book it now (release 33)
When you send an offer, tick **Book it now (no renter approval)** when the renter has already agreed. The offer goes out and an Admin approves it in one tap: the booking then waits for payment, the car is held, and the renter gets one link to sign and pay. You can also have them sign and pay with you: open the booking, **Sign now on this device**, then take the card on this device.
Already sent the offer? Ask the assistant: "Book the offer of CC-10482 now, the customer agreed by phone". It shows a card; **Confirm** sends the same request to an Admin, who approves in one tap.

## Switch a booking between card coverage and the Protection Plan (release 35)

When a renter''s card does not cover the car, or they want the plan instead, switch the booking yourself. On the booking page, open the **Coverage** card.

1. Press **Switch to the Protection Plan**. You see the plan''s price with HST and the new total before you confirm.
2. Write the reason (the renter reads it). On a confirmed booking or a rental in progress you can type the plan''s price for this booking, for example for the days left.
3. Press the button. An offer is sent again with the new price. A confirmed booking gets the plan line and the extra is open to collect on the Money tab: Collect sends the pay link. The renter is emailed what changed.

The card coverage proof and its review task are cleared for you. **Switch to card coverage** puts them back, or gives you a task to get the proof from the renter. Sales switches requests and offers only.

## Unanswered

**More customer service** > **Unanswered**: every customer text with no reply and every missed call not called back, oldest first. Reply or call back from the row; **Mark answered** when it was answered another way. After 15 minutes the team is alerted. Check WhatsApp by hand each morning.

## The request as sent and every offer (release 35)

On a request or a booking, **Original request, as the renter sent it** shows the car, dates, places, coverage, add-ons, note and the price the renter saw, exactly as sent; staff changes never touch it. **Offer history** lists every offer version, newest first: its status, who sent it and when, the car and dates, the message, how the total moved, and the price breakdown.

1. To go back to an old version, press **Revert to this offer** on it. Its car, dates, price, deposit, discount and fees load into the review as a new offer, highlighted.
2. Check the price, then send it in step 3. Nothing changes until you send.

The **Coverage** line at the top says what the renter chose (own insurance OPCF 27, credit card, Protection Plan) and its proof: not sent yet, waiting for review, confirmed, or rejected with the reason.

## Send an offer in three steps (release 35)

1. **Car and dates**: the renter, the dates, the car and where they pick it up and return it.
2. **Price**: filled in from the rate sheet with the checkout''s fees and discounts. Change it only if you agreed another price.
3. **Review and send**: what changed, the message and how the link goes.

Rarely used options (billing an insurer, how it is paid, the calendar) are under **More options**. Send waits while the price is being worked out again after a date change, and one tap sends once.

## The owner''s own trip, instant bookings and Book it now (release 35)

- **Owner''s own trip ($0)**: the owner booked their own car. There is nothing to price or send; get the car ready.
- **Instant (repeat renter)**: a renter with a completed rental, a verified licence and nothing owing booked an available car at once and went straight to sign and pay. An Admin can take a renter''s instant booking away from the booking page.
- **Book it now** pressed by staff waits for an Admin''s one-tap approval.

## Secondary contact and rideshare documents (release 35)

The booking shows the renter''s **Secondary contact** when they gave one: call them when the renter cannot be reached. Rideshare and delivery driving are welcome (rental agreement, section 10.3): never tell a renter it is not allowed. When a renter makes **rideshare documents** (Uber, Lyft, DoorDash and others), you get an alert and the booking shows the letters they made.

## Automatic answers (release 36)

Common questions by text, email, WhatsApp, Facebook and Instagram are answered by themselves from the FAQ. **Renter messages** > **Automatic answers** shows what was answered and what was left for a person. A question the FAQ does not answer stays for you: texts in Messages, emails and Meta messages as a To do, **Answer** and the question. Once you text someone, no automatic answer goes to them for 2 hours.

## The card the renter picked, and the two OPCF 27 pages (release 35)

On **Review documents** for a booking:

1. **Option 2**: **Card picked** names the card the renter chose from the list (or typed when it was not listed), and **Card check** says whether it covers this car: *Covers this car*, *Check it* (a card not on the list, a card whose coverage or value limit we do not know, or a car with no value on file) or *Does NOT cover this car* with the reason. **Approve** is refused while the card does not cover the car.
2. **Option 1**: each page says what it is: **pink slip** or **OPCF 27 endorsement**. **Approve** is refused until both are in. **Reject** needs the reason the renter sees.
3. A renter on OPCF 27 cannot pay until both pages are uploaded, so you see them before the booking is confirmed.

> Tip: Uploading a renter''s insurance yourself? In **Upload a document**, choose **Which page**: Pink slip or OPCF 27 endorsement page.

## Calls, auto-replies and coverage (releases 35 and 36)

- Calls from the Call button are recorded; the transcript, summary and Play recording are on the renter''s, lead''s and booking''s history. Quo calls show their transcript and summary there too.
- Automatic answers reply to common questions on every channel from our FAQ. A question they cannot answer becomes your To do: answer it yourself.
- Card coverage: the renter picks their card and the page checks it against the car. Approve OPCF 27 only with both the pink slip and the endorsement page.
- Rideshare and delivery work is allowed with the documents the renter makes on their booking; the secondary contact is on the booking.
- The mid-trip message asks the renter how the trip is going; a problem reported becomes your To do.

## Calls first, texts after (release 37)

Your main priority is always to be on the phone with people.

1. Answer a ringing call before anything else, and return a missed call at once.
2. **Call before you text.** On a lead, a renter or a booking, **Call** is the first button and **Text** the second.
3. A text is a follow-up: after a call attempt (no answer, a voicemail left), or when the person asked for a text.
4. On your To do and on **Unanswered**, missed calls and call-backs are listed above unanswered texts.

## A lead you handle on a call (release 37)

When you answer or place a call with a lead, add a note on it, or create it from a call, the lead is yours for a limited time (15 minutes, as a Sales claim; an Admin can change it in **Settings** > **Sales**). Every call you handle adds the time again.

- Sales see **Being handled by** your first name and your function with the time, on the lead and in every list. They cannot claim it, call, text or email it, or set an outcome meanwhile, and **Next lead** skips it.
- Another customer service or Fleet person can still work it; their call or note takes the hold over.
- When it ends, the lead goes back to the salesperson who had a claim on it or who brought it, else to the open list. An Admin can **Release hold** earlier.
- A booking made from the lead is credited as always: customer service and Fleet get no sales commission for it.
- Nobody who has not finished onboarding holds a lead.', 'Customer service', 'Requests and offers, new quotes, renter messages, find a renter, owner forms, late returns.',
  'You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter''s first person. There is no commission for customer service, but your help is credited on the booking (Helped by) and on your scorecard.

Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.

## Answer a request

1. Open **Requests and offers**: one queue (the numbers at the top are filters; **Active** always shows everything), the most urgent first, with how long each renter has waited, the countdown to the 2 hours the site promises, the car''s photo, the renter with **Call** and **Text**, the licence and one button (**Send offer**, **Follow up** or **Open**). Filter by Active, New, Asked the renter, Changes asked, Offer out, Not paid or Expired; an expired offer moves to Expired after 48 hours.
2. Waiting shows how long the renter has waited. Open the booking number.

![](/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg "desktop; size: 1440 640; address: carmacars.ca/va/requests; pins: 1 27.1 17.5, 2 52.8 32.8")

3. On the Review tab, check the request: the car is free, the renter, the places.
4. Press **Adjust the booking** to change the car, dates, places, price or extras, then **Save changes**.
5. Add a message and press **Send the offer**. Within your limit you can also use **Approve (within my limit)** or **Approve and send the pay link**.
6. Can''t do it? **Decline** with Reason and any alternative. Need to know more? **Ask the renter**.

![](/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg "desktop; size: 1440 1000; address: carmacars.ca/va/bookings/CC-10069?tab=review; pins: 3 69.4 24.0, 4 95.8 98.0")

> Tip: Reply within 5 minutes: send the offer, or ask the renter what you need. That is the "First reply in opening hours" measure on your scorecard. Requests waiting longer show in red.

Opening a request takes it for you: the others see "Being answered by" your name and cannot answer it until you send, decline or leave (20 minutes, renewed while you work). One someone else holds shows who, with the buttons off; it opens to you when their claim runs out, or ask an Admin to take it over. Sales: a request from the website shows "Opens to you at" a time for its first 15 minutes, and a To do task says when it opens; after that whoever opens it first answers it, customer service included.

## An enquiry on an example car

Some cars on the site are marked "Example car": samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.

1. The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact. When a real car was free for those dates, the task names it after **Free:** (the same make and model first, else the same class and body at a similar price), and the person was told we have a similar car and will confirm it within 2 hours.
2. Check the named car is still right for them (or find a real car of the same kind and price that is free for those dates), and make a **New quote** for it.
3. Call or email the person with the car and the price, then mark the task done.

> Tip: Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.

## A request from a vehicle page

Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.

1. The request arrives as an enquiry with the car named in the message ("About the car: 2023 Toyota RAV4 XLE") and an Enquiry task in To do.
2. If we have that car, or one close to it, free for their dates, make a **New quote** for it. If not, suggest the nearest car of the same kind and price.
3. Reply by email or phone, then mark the task done.

> Tip: The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.

## A buyer lead from a /buy page

Every vehicle page has a for-sale twin (carmacars.ca/buy/toyota/rav4/2023/xle) with "Find me this car", and twins for financing, detailing and body shop work with their own request: a name, an email or phone, and when.

1. The lead is in **Buyer leads** (customer service: **Owners and enquiries**), Buyer leads (kind buyer, finance, detailing or body shop), with the car and what they asked, and a To do line for Sales: A buyer asked us to find a car, Someone asked about financing or leasing a car, A detailing request, or A body shop request.
2. If one of our cars of that kind is for sale (an Admin flags it with its price), offer it. If not, offer to rent them the car for a week first, and say what we can find. We do not lend or lease: on a financing question, say so and offer the rental. For detailing or body shop work, give a time and a price, and always offer a rental while their car is in (an insurance replacement rental when it is a claim). For mechanical work (a "Mechanical work to arrange" task: an oil change, brakes, tires, a tow and the like), CarmaCars does not do the work: book it with a trusted shop or recommend one, never promise the shop''s price or time, and offer a rental while their car is in.
3. Press **Take it**, then **Update** as you go: contacted, qualified, converted or closed with the reason.

> Tip: We mostly rent cars. Never say a car is for sale unless an Admin flagged it; the page shows it with its price when one is.

## Send an offer to a caller

Open **Send an offer** (or **Send an offer** beside a car in Find a car). No request needed: one screen, and the renter has the link.

1. Find the customer by name, phone or email, or press **Add a new customer**: full legal name, mobile, email and date of birth. Already on file with that email or phone? Use them: never a second record.
2. Choose the car (by car code, plate or name; each says Free or Not free), the dates and the places.
3. The price: the rate sheet, a total or a rate per day, with the reason for a price you type. The deposit, discounts and fees are set by an Admin; customer service sets the Protection Plan price. Amounts I type, at the top of the price: Before tax, or After tax (HST included) to type what the renter pays, worked back to before tax for you. Or type the Total the renter pays (after tax): the rental charge is worked out from it.
4. How the rental and the deposit are paid (card online, e-Transfer, cash, platform payout, the insurer; deposit by card hold, cash or e-Transfer), who found this client, the message, how long it is open (48 hours at most) and Email, Text or both.
5. Check the offer as the renter will see it on the right, then press **Send the offer**.

> Tip: An offer that is out is changed in place: **More actions** > **Edit the offer**, change it, then **Save and send the update** or **Save without telling the renter**. No need to withdraw it first.

## New quote for a caller

1. Open **New quote**. Choose the Car, the Pickup and Return (at least 2 hours from now).
2. Choose how the lead came in, then the caller''s Full legal name, Email, Mobile and Date of birth.
3. Set the Licence class and Damage cover, and note places, extras and what they asked.
4. Press **Create the request**. It opens like any request; send the offer from there.

![](/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg "desktop; size: 1220 1260; address: carmacars.ca/va/quotes/new; pins: 1 72.1 15.6, 2 72.1 41.7, 3 72.1 72.7, 4 63.9 85.5")

## Edit a booking, a fee or the renter

A booking that is confirmed, on trip or returned is edited directly; the renter''s details are corrected from the booking.

1. Overview, **Edit the booking**: the return (extend or shorten), the car, the rental charge, each fee, the kilometres and the note. Tick **Email the renter what changed**, or leave it off for a silent correction.
2. Money tab, Fees, **Change or add a fee**: a fee forgotten (the young driver fee shows its price for the dates) or a charge of its own.
3. What is open shows at once: **Email a pay link** or **Text a pay link** for exactly that amount, or record cash or an e-Transfer (Rental charges, Collect (the amount) rental, **Cash, e-Transfer or another way (record it)**).
4. **Edit renter**: a wrong email, phone, name, licence or address. A new email is their sign-in at once.
5. The same renter twice? Under the renter, Possible duplicates: **Merge into this record** moves everything of the other record here.

> Good to know: Each edit is recorded with your name, the time, the reason and the before and after.

## Renter messages and Find a renter

1. **Renter messages** lists the latest messages with their booking. Open the booking to reply, then press **Send**.
2. **Find a renter**: search by name, email, phone or booking number.
3. To open a renter''s private details, press **Open with a reason**. The reason is kept in the access log.

![](/guides/img/va-cs-06-messages-desktop-3441fa91.jpg "desktop; size: 1440 260; address: carmacars.ca/va/messages; pins: 1 32.6 48.5")

## Add a car for an owner

Open **Owners** > **Add a car for an owner** (fleet: under Cars). You enter everything for the owner; they never fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN. The car is looked up at once and shown in one line with the year, make, model, trim and details (Edit if something is wrong). No VIN at hand: add it by its plate and choose the year, make and model. Tap the colour and check the class. Upload the ownership permit, the insurance slip and the lender''s information if you have them. Photos are optional.
3. Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner. The owner signs in the owner portal after one email (no paper signature).
5. Press **Add the car and send to an Admin**. The application waits in the Admin''s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.

> Good to know: A fleet supplier (a corporation leasing its cars to CarmaCars): choose New owner, **A corporation**, then Route **Fleet supplier: leases the cars to CarmaCars**. The default lease terms are set at once. For the car, enter the VIN, the plate and the ownership copy, choose its tier, **Regular** or **Troubled** (it is set once), and who it is registered to now (for a car moving in or bought, the name and address on the ownership and the date). Its ServiceOntario forms are filled in at once. No terms, no invoices and no paper signing: the supplier signs in the owner portal. The car goes on the lease when an Admin approves it.

## Owners: the checklist, the photos and the forms (release 34)

Open **Owners** (customer service and fleet), then an owner. Search finds any owner by name, email, plate or VIN.

1. The **Onboarding checklist**: per car, each step done, to do (and who it waits on), blocked (and why) or not needed, with the one button to press.
2. **Onboarding photos**: **Replace** or **Remove** (with a reason) a wrong ownership permit, insurance slip or lender''s letter, or **Approve** or mark it **Not accepted** (the owner reads why). A replaced photo is checked again.
3. **Government forms**: each ServiceOntario form the car needs, made by themselves, with its status, the date it was made and its download.
4. **Add cars from a list of VINs** for the owner: paste or upload, **Preview**, **Add**.

## Owner forms (Forms C and D)

1. Open **Owner forms**. Each row is a scan an owner uploaded before November 2026 (Forms C and D are signed on screen since then), with the witnesses and the status.
2. Press Open to read the scan. Check every page is there and signed, with each witness''s signature and name.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg "desktop; size: 1440 300; address: carmacars.ca/va/owner-forms; pins: 2 68.6 36.7, 3 76.7 36.7")

## Rental agreements are signed online only

A rental agreement, or a booking change, is signed by the renter in their portal or on the phone at the handover (the e-signature). A copy signed on paper is not accepted or recorded: send the renter the link again from the booking. One recorded before November 2026 stays readable under Signed on paper.

## Signatures on the spot, or by link

A renter or an additional driver who has not signed yet.

1. On the booking, press **Sign now on this device**. Confirm the name and that you saw the original licence, then **Hand the device to** the signer.
2. Or press **Email the signing link** or **Text the signing link**: they sign on their own phone.
3. The licence comes first: the renter uploads it from the request, and the offer cannot be accepted without it.

## The booking''s rental agreements

The Rental agreements card keeps both agreements in step with the booking.

1. Any change after signing makes a new version by itself. A change to the dates, the price, the car, the drivers or the coverage waits for the renter''s signature: they get the link by email and text, and the card says "Agreement v3 waiting for signature".
2. **Resend the signing links**, or press the button with their first name beside it to have them sign on your device.
3. Fields still blank (a licence expiry, an insurer''s policy number) are listed: type them and press **Save the missing fields**. Check-in stops on a field a claim needs until it is filled or an Admin overrides.
4. Every signature: a code to the signer''s phone or email, the key terms initialled, three consents, a drawn signature.

## Check renter documents

The renter''s licence photos, selfie and proof of coverage, before the handover.

1. Open the task "identity documents or coverage proof to review", or open the booking: **Review** shows the documents of any booking being arranged or under way, with no task needed.
2. Every licence image, selfie and proof of coverage of the booking is on one screen, with what to check written once above them: the selfie matches, no alteration, the coverage is active to the return date.
3. Under each driver, the licence reader lists what it read (from the back''s barcode, else the photo) and one line per check, Pass or Flag: photos sharp and whole, valid to the return, class accepted, old enough at pickup, name and date of birth match the driver, the Ontario number, front and back the same licence, and the main driver''s Ontario licence. Look closely at each Flag.
4. One is wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**.
5. Then press **Approve all**: everything still waiting is approved at once (the Protection Plan too). A document the system refuses is named with the reason; the rest are approved.

> Tip: Each opening is logged. An Admin can do the same from Admin > To do. Field staff review the licence images (not the coverage) of bookings on their own jobs in the next 7 days from their My jobs: the booking history says the role, field.

> Good to know: Main driver: Ontario licence needed. When the main driver''s licence is from elsewhere, they are moved to additional driver (their photos and checks stay; you still review them) and pickup is blocked until a driver with an Ontario licence is the main driver. The renter adds one from their booking. Only an Admin can undo the swap or let it go with a reason.

## Which credit cards include rental car coverage?

Renters ask this often. **Renters** > **Card coverage** (every function has it under Rentals or Bookings) is your quick reference: what to say, what to check, and the list.

1. Send the renter `carmacars.ca/credit-card-rental-coverage`: each card''s car value limit (MSRP), longest rental, key exclusions, its official guide and the day we last checked it.
2. Ask which car they want. Most Canadian cards stop at a car priced $65,000 or $85,000, and many luxury models are priced higher. Give them the car''s model year and trim so they can check.
3. Never tell a renter they are covered. Their card''s issuer decides that: ask them to call the number on the back of their card about this car and these dates. CarmaCars does not decide claims.
4. Over the limit, an excluded make, a debit card or a longer rental than the card allows: offer OPCF 27 on their own auto policy or the CarmaCars Protection Plan.

> Tip: A card marked Unverified came from a published summary, not the issuer''s guide. Something wrong or out of date in the list? Tell an Admin: they correct it in Settings > Card coverage.

## Review requests

Renters are asked for a review by email and text after each trip. **Renters** > **Review requests** shows the ones on hold and the Google reviews to match.

1. On hold: the booking has a charge that is not settled or waived yet (late return, kilometres, fuel, cleaning, smoking, damage, tolls) or an open incident. It leaves the list by itself once the charges are settled or waived.
2. The renter should be asked now anyway? Press **Send anyway**. Should never be asked? Press **Do not ask**.
3. Google reviews: a possible match to a renter shows "possible match". Press **Confirm** if it is them, **Not this renter** if not, or **Match to a booking** with the booking number.
4. A review that came another way (Turo, a text, a call, email): press **Add a customer review** and type the customer''s first name and last initial, the source, the date received, the rating and their words exactly as received, with a screenshot if you have one. It shows on the site with its source. Never write or change a review for a customer.
5. On a booking, the card Review requests has **Ask for a review** (for example after a call that went well) and **Mark reviewed** when the renter says they already left one.

> Tip: Never offer anything for a review and never ask only happy renters: everyone gets the same message and the same Google link.

## A change to a confirmed booking

On a booking''s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press **Preview the price**, then **Send to the renter**. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.

## A late return

A booking past its return time shows the late return panel. The renter can still extend in their booking while they have the car: the extension counts from the original return time, it is approved at once when the car is free, and paying it stops the late notices. Point them to **Extend** first. Otherwise work it in order:

| Button | When |
| --- | --- |
| **Log a call** | Record each call to the renter and what they said. |
| **Send T13** | The first late notice email. |
| **Send T14 (final notice)** | The final notice. |
| **Request disable** | Ask an Admin to approve disabling the car. |
| **Open an incident** | When the car is not coming back as planned. |

## Booked when the renter accepts (release 28)

A renter who approves the offer has booked the car, even before paying: the booking shows **Booked, payment due** and holds the car everywhere. Collect the payment before the pickup (a **Booked, payment due** To do comes 48 hours before). When you send an offer, the renter''s view is right under **Send the offer**.

## When a check stops the pickup or the return (release 33)
On the booking page, **What stops the pickup now** (or the return) lists each check that stops it, in plain words. When the trip must go ahead anyway, press **Ask an Admin to override the pickup** (or the return), give the actual time, the km and fuel if you know them, and why. An Admin gets an alert and approves in one tap; the pickup (or the return) is then recorded with the time you entered, and the booking''s history says who asked and who approved. You can cancel your request while it waits. A trip that happened and was never recorded: **Ask to record a past trip** with both times; once an Admin approves, the booking lands in Returned so the deposit can be settled.

## Book it now (release 33)
When you send an offer, tick **Book it now (no renter approval)** when the renter has already agreed. The offer goes out and an Admin approves it in one tap: the booking then waits for payment, the car is held, and the renter gets one link to sign and pay. You can also have them sign and pay with you: open the booking, **Sign now on this device**, then take the card on this device.
Already sent the offer? Ask the assistant: "Book the offer of CC-10482 now, the customer agreed by phone". It shows a card; **Confirm** sends the same request to an Admin, who approves in one tap.

## Switch a booking between card coverage and the Protection Plan (release 35)

When a renter''s card does not cover the car, or they want the plan instead, switch the booking yourself. On the booking page, open the **Coverage** card.

1. Press **Switch to the Protection Plan**. You see the plan''s price with HST and the new total before you confirm.
2. Write the reason (the renter reads it). On a confirmed booking or a rental in progress you can type the plan''s price for this booking, for example for the days left.
3. Press the button. An offer is sent again with the new price. A confirmed booking gets the plan line and the extra is open to collect on the Money tab: Collect sends the pay link. The renter is emailed what changed.

The card coverage proof and its review task are cleared for you. **Switch to card coverage** puts them back, or gives you a task to get the proof from the renter. Sales switches requests and offers only.

## Unanswered

**More customer service** > **Unanswered**: every customer text with no reply and every missed call not called back, oldest first. Reply or call back from the row; **Mark answered** when it was answered another way. After 15 minutes the team is alerted. Check WhatsApp by hand each morning.

## The request as sent and every offer (release 35)

On a request or a booking, **Original request, as the renter sent it** shows the car, dates, places, coverage, add-ons, note and the price the renter saw, exactly as sent; staff changes never touch it. **Offer history** lists every offer version, newest first: its status, who sent it and when, the car and dates, the message, how the total moved, and the price breakdown.

1. To go back to an old version, press **Revert to this offer** on it. Its car, dates, price, deposit, discount and fees load into the review as a new offer, highlighted.
2. Check the price, then send it in step 3. Nothing changes until you send.

The **Coverage** line at the top says what the renter chose (own insurance OPCF 27, credit card, Protection Plan) and its proof: not sent yet, waiting for review, confirmed, or rejected with the reason.

## Send an offer in three steps (release 35)

1. **Car and dates**: the renter, the dates, the car and where they pick it up and return it.
2. **Price**: filled in from the rate sheet with the checkout''s fees and discounts. Change it only if you agreed another price.
3. **Review and send**: what changed, the message and how the link goes.

Rarely used options (billing an insurer, how it is paid, the calendar) are under **More options**. Send waits while the price is being worked out again after a date change, and one tap sends once.

## The owner''s own trip, instant bookings and Book it now (release 35)

- **Owner''s own trip ($0)**: the owner booked their own car. There is nothing to price or send; get the car ready.
- **Instant (repeat renter)**: a renter with a completed rental, a verified licence and nothing owing booked an available car at once and went straight to sign and pay. An Admin can take a renter''s instant booking away from the booking page.
- **Book it now** pressed by staff waits for an Admin''s one-tap approval.

## Secondary contact and rideshare documents (release 35)

The booking shows the renter''s **Secondary contact** when they gave one: call them when the renter cannot be reached. Rideshare and delivery driving are welcome (rental agreement, section 10.3): never tell a renter it is not allowed. When a renter makes **rideshare documents** (Uber, Lyft, DoorDash and others), you get an alert and the booking shows the letters they made.

## Automatic answers (release 36)

Common questions by text, email, WhatsApp, Facebook and Instagram are answered by themselves from the FAQ. **Renter messages** > **Automatic answers** shows what was answered and what was left for a person. A question the FAQ does not answer stays for you: texts in Messages, emails and Meta messages as a To do, **Answer** and the question. Once you text someone, no automatic answer goes to them for 2 hours.

## The card the renter picked, and the two OPCF 27 pages (release 35)

On **Review documents** for a booking:

1. **Option 2**: **Card picked** names the card the renter chose from the list (or typed when it was not listed), and **Card check** says whether it covers this car: *Covers this car*, *Check it* (a card not on the list, a card whose coverage or value limit we do not know, or a car with no value on file) or *Does NOT cover this car* with the reason. **Approve** is refused while the card does not cover the car.
2. **Option 1**: each page says what it is: **pink slip** or **OPCF 27 endorsement**. **Approve** is refused until both are in. **Reject** needs the reason the renter sees.
3. A renter on OPCF 27 cannot pay until both pages are uploaded, so you see them before the booking is confirmed.

> Tip: Uploading a renter''s insurance yourself? In **Upload a document**, choose **Which page**: Pink slip or OPCF 27 endorsement page.

## Calls, auto-replies and coverage (releases 35 and 36)

- Calls from the Call button are recorded; the transcript, summary and Play recording are on the renter''s, lead''s and booking''s history. Quo calls show their transcript and summary there too.
- Automatic answers reply to common questions on every channel from our FAQ. A question they cannot answer becomes your To do: answer it yourself.
- Card coverage: the renter picks their card and the page checks it against the car. Approve OPCF 27 only with both the pink slip and the endorsement page.
- Rideshare and delivery work is allowed with the documents the renter makes on their booking; the secondary contact is on the booking.
- The mid-trip message asks the renter how the trip is going; a problem reported becomes your To do.

## Calls first, texts after (release 37)

Your main priority is always to be on the phone with people.

1. Answer a ringing call before anything else, and return a missed call at once.
2. **Call before you text.** On a lead, a renter or a booking, **Call** is the first button and **Text** the second.
3. A text is a follow-up: after a call attempt (no answer, a voicemail left), or when the person asked for a text.
4. On your To do and on **Unanswered**, missed calls and call-backs are listed above unanswered texts.

## A lead you handle on a call (release 37)

When you answer or place a call with a lead, add a note on it, or create it from a call, the lead is yours for a limited time (15 minutes, as a Sales claim; an Admin can change it in **Settings** > **Sales**). Every call you handle adds the time again.

- Sales see **Being handled by** your first name and your function with the time, on the lead and in every list. They cannot claim it, call, text or email it, or set an outcome meanwhile, and **Next lead** skips it.
- Another customer service or Fleet person can still work it; their call or note takes the hold over.
- When it ends, the lead goes back to the salesperson who had a claim on it or who brought it, else to the open list. An Admin can **Release hold** earlier.
- A booking made from the lead is credited as always: customer service and Fleet get no sales commission for it.
- Nobody who has not finished onboarding holds a lead.

## The person behind the lead (release 40)

On **Leads**, press **The person** on a card, or open the lead, to see the whole person: contact, account and licence verified (yes or no), bookings and balances, deposit, requests and offers, earlier leads, messages, calls and texts, notes, reviews, incidents, who has handled them, and the **Signals** timeline of everything they did with us. Outside the renter''s window you see it in full while you hold the lead on a call; otherwise you see the contact and account.',
  '<p class="gd-p">You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter&#39;s first person. There is no commission for customer service, but your help is credited on the booking (Helped by) and on your scorecard.</p><p class="gd-p">Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.</p><section class="gd-task" id="customer-service-answer-a-request" data-gd-task><h2 class="gd-h2">Answer a request</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Requests and offers</b>: one queue (the numbers at the top are filters; <b class="gd-ui">Active</b> always shows everything), the most urgent first, with how long each renter has waited, the countdown to the 2 hours the site promises, the car&#39;s photo, the renter with <b class="gd-ui">Call</b> and <b class="gd-ui">Text</b>, the licence and one button (<b class="gd-ui">Send offer</b>, <b class="gd-ui">Follow up</b> or <b class="gd-ui">Open</b>). Filter by Active, New, Asked the renter, Changes asked, Offer out, Not paid or Expired; an expired offer moves to Expired after 48 hours.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Waiting shows how long the renter has waited. Open the booking number.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:27.1%;top:17.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:52.8%;top:32.8%" aria-hidden="true">2</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the Review tab, check the request: the car is free, the renter, the places.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Adjust the booking</b> to change the car, dates, places, price or extras, then <b class="gd-ui">Save changes</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Add a message and press <b class="gd-ui">Send the offer</b>. Within your limit you can also use <b class="gd-ui">Approve (within my limit)</b> or <b class="gd-ui">Approve and send the pay link</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Can&#39;t do it? <b class="gd-ui">Decline</b> with Reason and any alternative. Need to know more? <b class="gd-ui">Ask the renter</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/bookings/CC-10069?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:69.4%;top:24%" aria-hidden="true">3</span><span class="gd-pin" style="left:95.8%;top:98%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Reply within 5 minutes: send the offer, or ask the renter what you need. That is the &quot;First reply in opening hours&quot; measure on your scorecard. Requests waiting longer show in red.</div></aside><p class="gd-p">Opening a request takes it for you: the others see &quot;Being answered by&quot; your name and cannot answer it until you send, decline or leave (20 minutes, renewed while you work). One someone else holds shows who, with the buttons off; it opens to you when their claim runs out, or ask an Admin to take it over. Sales: a request from the website shows &quot;Opens to you at&quot; a time for its first 15 minutes, and a To do task says when it opens; after that whoever opens it first answers it, customer service included.</p></section><section class="gd-task" id="customer-service-an-enquiry-on-an-example-car" data-gd-task><h2 class="gd-h2">An enquiry on an example car</h2><p class="gd-p">Some cars on the site are marked &quot;Example car&quot;: samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact. When a real car was free for those dates, the task names it after <b class="gd-ui">Free:</b> (the same make and model first, else the same class and body at a similar price), and the person was told we have a similar car and will confirm it within 2 hours.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the named car is still right for them (or find a real car of the same kind and price that is free for those dates), and make a <b class="gd-ui">New quote</b> for it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Call or email the person with the car and the price, then mark the task done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.</div></aside></section><section class="gd-task" id="customer-service-a-request-from-a-vehicle-page" data-gd-task><h2 class="gd-h2">A request from a vehicle page</h2><p class="gd-p">Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The request arrives as an enquiry with the car named in the message (&quot;About the car: 2023 Toyota RAV4 XLE&quot;) and an Enquiry task in To do.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">If we have that car, or one close to it, free for their dates, make a <b class="gd-ui">New quote</b> for it. If not, suggest the nearest car of the same kind and price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Reply by email or phone, then mark the task done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.</div></aside></section><section class="gd-task" id="customer-service-a-buyer-lead-from-a-buy-page" data-gd-task><h2 class="gd-h2">A buyer lead from a /buy page</h2><p class="gd-p">Every vehicle page has a for-sale twin (carmacars.ca/buy/toyota/rav4/2023/xle) with &quot;Find me this car&quot;, and twins for financing, detailing and body shop work with their own request: a name, an email or phone, and when.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The lead is in <b class="gd-ui">Buyer leads</b> (customer service: <b class="gd-ui">Owners and enquiries</b>), Buyer leads (kind buyer, finance, detailing or body shop), with the car and what they asked, and a To do line for Sales: A buyer asked us to find a car, Someone asked about financing or leasing a car, A detailing request, or A body shop request.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">If one of our cars of that kind is for sale (an Admin flags it with its price), offer it. If not, offer to rent them the car for a week first, and say what we can find. We do not lend or lease: on a financing question, say so and offer the rental. For detailing or body shop work, give a time and a price, and always offer a rental while their car is in (an insurance replacement rental when it is a claim). For mechanical work (a &quot;Mechanical work to arrange&quot; task: an oil change, brakes, tires, a tow and the like), CarmaCars does not do the work: book it with a trusted shop or recommend one, never promise the shop&#39;s price or time, and offer a rental while their car is in.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Take it</b>, then <b class="gd-ui">Update</b> as you go: contacted, qualified, converted or closed with the reason.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>We mostly rent cars. Never say a car is for sale unless an Admin flagged it; the page shows it with its price when one is.</div></aside></section><section class="gd-task" id="customer-service-send-an-offer-to-a-caller" data-gd-task><h2 class="gd-h2">Send an offer to a caller</h2><p class="gd-p">Open <b class="gd-ui">Send an offer</b> (or <b class="gd-ui">Send an offer</b> beside a car in Find a car). No request needed: one screen, and the renter has the link.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Find the customer by name, phone or email, or press <b class="gd-ui">Add a new customer</b>: full legal name, mobile, email and date of birth. Already on file with that email or phone? Use them: never a second record.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the car (by car code, plate or name; each says Free or Not free), the dates and the places.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The price: the rate sheet, a total or a rate per day, with the reason for a price you type. The deposit, discounts and fees are set by an Admin; customer service sets the Protection Plan price. Amounts I type, at the top of the price: Before tax, or After tax (HST included) to type what the renter pays, worked back to before tax for you. Or type the Total the renter pays (after tax): the rental charge is worked out from it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">How the rental and the deposit are paid (card online, e-Transfer, cash, platform payout, the insurer; deposit by card hold, cash or e-Transfer), who found this client, the message, how long it is open (48 hours at most) and Email, Text or both.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Check the offer as the renter will see it on the right, then press <b class="gd-ui">Send the offer</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>An offer that is out is changed in place: <b class="gd-ui">More actions</b> &gt; <b class="gd-ui">Edit the offer</b>, change it, then <b class="gd-ui">Save and send the update</b> or <b class="gd-ui">Save without telling the renter</b>. No need to withdraw it first.</div></aside></section><section class="gd-task" id="customer-service-new-quote-for-a-caller" data-gd-task><h2 class="gd-h2">New quote for a caller</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">New quote</b>. Choose the Car, the Pickup and Return (at least 2 hours from now).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose how the lead came in, then the caller&#39;s Full legal name, Email, Mobile and Date of birth.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Set the Licence class and Damage cover, and note places, extras and what they asked.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Create the request</b>. It opens like any request; send the offer from there.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/quotes/new</span></div><div class="gd-imgwrap" style="aspect-ratio:1220/1260"><img src="/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg" alt="" loading="lazy" decoding="async" width="1220" height="1260"><span class="gd-pin" style="left:72.1%;top:15.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:72.1%;top:41.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:72.1%;top:72.7%" aria-hidden="true">3</span><span class="gd-pin" style="left:63.9%;top:85.5%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="customer-service-edit-a-booking-a-fee-or-the-renter" data-gd-task><h2 class="gd-h2">Edit a booking, a fee or the renter</h2><p class="gd-p">A booking that is confirmed, on trip or returned is edited directly; the renter&#39;s details are corrected from the booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Overview, <b class="gd-ui">Edit the booking</b>: the return (extend or shorten), the car, the rental charge, each fee, the kilometres and the note. Tick <b class="gd-ui">Email the renter what changed</b>, or leave it off for a silent correction.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Money tab, Fees, <b class="gd-ui">Change or add a fee</b>: a fee forgotten (the young driver fee shows its price for the dates) or a charge of its own.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">What is open shows at once: <b class="gd-ui">Email a pay link</b> or <b class="gd-ui">Text a pay link</b> for exactly that amount, or record cash or an e-Transfer (Rental charges, Collect (the amount) rental, <b class="gd-ui">Cash, e-Transfer or another way (record it)</b>).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Edit renter</b>: a wrong email, phone, name, licence or address. A new email is their sign-in at once.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The same renter twice? Under the renter, Possible duplicates: <b class="gd-ui">Merge into this record</b> moves everything of the other record here.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each edit is recorded with your name, the time, the reason and the before and after.</div></aside></section><section class="gd-task" id="customer-service-renter-messages-and-find-a-renter" data-gd-task><h2 class="gd-h2">Renter messages and Find a renter</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Renter messages</b> lists the latest messages with their booking. Open the booking to reply, then press <b class="gd-ui">Send</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Find a renter</b>: search by name, email, phone or booking number.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To open a renter&#39;s private details, press <b class="gd-ui">Open with a reason</b>. The reason is kept in the access log.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/messages</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/260"><img src="/guides/img/va-cs-06-messages-desktop-3441fa91.jpg" alt="" loading="lazy" decoding="async" width="1440" height="260"><span class="gd-pin" style="left:32.6%;top:48.5%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="customer-service-add-a-car-for-an-owner" data-gd-task><h2 class="gd-h2">Add a car for an owner</h2><p class="gd-p">Open <b class="gd-ui">Owners</b> &gt; <b class="gd-ui">Add a car for an owner</b> (fleet: under Cars). You enter everything for the owner; they never fill in the application.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car: type the VIN. The car is looked up at once and shown in one line with the year, make, model, trim and details (Edit if something is wrong). No VIN at hand: add it by its plate and choose the year, make and model. Tap the colour and check the class. Upload the ownership permit, the insurance slip and the lender&#39;s information if you have them. Photos are optional.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Who sourced the owner: Entered for CarmaCars, or I sourced this owner. The owner signs in the owner portal after one email (no paper signature).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Add the car and send to an Admin</b>. The application waits in the Admin&#39;s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A fleet supplier (a corporation leasing its cars to CarmaCars): choose New owner, <b class="gd-ui">A corporation</b>, then Route <b class="gd-ui">Fleet supplier: leases the cars to CarmaCars</b>. The default lease terms are set at once. For the car, enter the VIN, the plate and the ownership copy, choose its tier, <b class="gd-ui">Regular</b> or <b class="gd-ui">Troubled</b> (it is set once), and who it is registered to now (for a car moving in or bought, the name and address on the ownership and the date). Its ServiceOntario forms are filled in at once. No terms, no invoices and no paper signing: the supplier signs in the owner portal. The car goes on the lease when an Admin approves it.</div></aside></section><section class="gd-task" id="customer-service-owners-the-checklist-the-photos-and-the-forms-release-34" data-gd-task><h2 class="gd-h2">Owners: the checklist, the photos and the forms (release 34)</h2><p class="gd-p">Open <b class="gd-ui">Owners</b> (customer service and fleet), then an owner. Search finds any owner by name, email, plate or VIN.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The <b class="gd-ui">Onboarding checklist</b>: per car, each step done, to do (and who it waits on), blocked (and why) or not needed, with the one button to press.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Onboarding photos</b>: <b class="gd-ui">Replace</b> or <b class="gd-ui">Remove</b> (with a reason) a wrong ownership permit, insurance slip or lender&#39;s letter, or <b class="gd-ui">Approve</b> or mark it <b class="gd-ui">Not accepted</b> (the owner reads why). A replaced photo is checked again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Government forms</b>: each ServiceOntario form the car needs, made by themselves, with its status, the date it was made and its download.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Add cars from a list of VINs</b> for the owner: paste or upload, <b class="gd-ui">Preview</b>, <b class="gd-ui">Add</b>.</div></li></ol></div></section><section class="gd-task" id="customer-service-owner-forms-forms-c-and-d" data-gd-task><h2 class="gd-h2">Owner forms (Forms C and D)</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Owner forms</b>. Each row is a scan an owner uploaded before November 2026 (Forms C and D are signed on screen since then), with the witnesses and the status.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press Open to read the scan. Check every page is there and signed, with each witness&#39;s signature and name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Approve</b>, or <b class="gd-ui">Send back</b> with What to fix (the owner reads this).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/owner-forms</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/300"><img src="/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg" alt="" loading="lazy" decoding="async" width="1440" height="300"><span class="gd-pin" style="left:68.6%;top:36.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:76.7%;top:36.7%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="customer-service-rental-agreements-are-signed-online-only" data-gd-task><h2 class="gd-h2">Rental agreements are signed online only</h2><p class="gd-p">A rental agreement, or a booking change, is signed by the renter in their portal or on the phone at the handover (the e-signature). A copy signed on paper is not accepted or recorded: send the renter the link again from the booking. One recorded before November 2026 stays readable under Signed on paper.</p></section><section class="gd-task" id="customer-service-signatures-on-the-spot-or-by-link" data-gd-task><h2 class="gd-h2">Signatures on the spot, or by link</h2><p class="gd-p">A renter or an additional driver who has not signed yet.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the booking, press <b class="gd-ui">Sign now on this device</b>. Confirm the name and that you saw the original licence, then <b class="gd-ui">Hand the device to</b> the signer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Or press <b class="gd-ui">Email the signing link</b> or <b class="gd-ui">Text the signing link</b>: they sign on their own phone.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The licence comes first: the renter uploads it from the request, and the offer cannot be accepted without it.</div></li></ol></div></section><section class="gd-task" id="customer-service-the-booking-s-rental-agreements" data-gd-task><h2 class="gd-h2">The booking&#39;s rental agreements</h2><p class="gd-p">The Rental agreements card keeps both agreements in step with the booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Any change after signing makes a new version by itself. A change to the dates, the price, the car, the drivers or the coverage waits for the renter&#39;s signature: they get the link by email and text, and the card says &quot;Agreement v3 waiting for signature&quot;.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Resend the signing links</b>, or press the button with their first name beside it to have them sign on your device.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Fields still blank (a licence expiry, an insurer&#39;s policy number) are listed: type them and press <b class="gd-ui">Save the missing fields</b>. Check-in stops on a field a claim needs until it is filled or an Admin overrides.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Every signature: a code to the signer&#39;s phone or email, the key terms initialled, three consents, a drawn signature.</div></li></ol></div></section><section class="gd-task" id="customer-service-check-renter-documents" data-gd-task><h2 class="gd-h2">Check renter documents</h2><p class="gd-p">The renter&#39;s licence photos, selfie and proof of coverage, before the handover.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the task &quot;identity documents or coverage proof to review&quot;, or open the booking: <b class="gd-ui">Review</b> shows the documents of any booking being arranged or under way, with no task needed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Every licence image, selfie and proof of coverage of the booking is on one screen, with what to check written once above them: the selfie matches, no alteration, the coverage is active to the return date.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Under each driver, the licence reader lists what it read (from the back&#39;s barcode, else the photo) and one line per check, Pass or Flag: photos sharp and whole, valid to the return, class accepted, old enough at pickup, name and date of birth match the driver, the Ontario number, front and back the same licence, and the main driver&#39;s Ontario licence. Look closely at each Flag.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">One is wrong? Open <b class="gd-ui">Reject this one</b> under it, type the reason the renter reads and press <b class="gd-ui">Reject</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Then press <b class="gd-ui">Approve all</b>: everything still waiting is approved at once (the Protection Plan too). A document the system refuses is named with the reason; the rest are approved.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Each opening is logged. An Admin can do the same from Admin &gt; To do. Field staff review the licence images (not the coverage) of bookings on their own jobs in the next 7 days from their My jobs: the booking history says the role, field.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Main driver: Ontario licence needed. When the main driver&#39;s licence is from elsewhere, they are moved to additional driver (their photos and checks stay; you still review them) and pickup is blocked until a driver with an Ontario licence is the main driver. The renter adds one from their booking. Only an Admin can undo the swap or let it go with a reason.</div></aside></section><section class="gd-task" id="customer-service-which-credit-cards-include-rental-car-coverage" data-gd-task><h2 class="gd-h2">Which credit cards include rental car coverage?</h2><p class="gd-p">Renters ask this often. <b class="gd-ui">Renters</b> &gt; <b class="gd-ui">Card coverage</b> (every function has it under Rentals or Bookings) is your quick reference: what to say, what to check, and the list.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Send the renter <span class="gd-url">carmacars.ca/credit-card-rental-coverage</span>: each card&#39;s car value limit (MSRP), longest rental, key exclusions, its official guide and the day we last checked it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Ask which car they want. Most Canadian cards stop at a car priced $65,000 or $85,000, and many luxury models are priced higher. Give them the car&#39;s model year and trim so they can check.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Never tell a renter they are covered. Their card&#39;s issuer decides that: ask them to call the number on the back of their card about this car and these dates. CarmaCars does not decide claims.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Over the limit, an excluded make, a debit card or a longer rental than the card allows: offer OPCF 27 on their own auto policy or the CarmaCars Protection Plan.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A card marked Unverified came from a published summary, not the issuer&#39;s guide. Something wrong or out of date in the list? Tell an Admin: they correct it in Settings &gt; Card coverage.</div></aside></section><section class="gd-task" id="customer-service-review-requests" data-gd-task><h2 class="gd-h2">Review requests</h2><p class="gd-p">Renters are asked for a review by email and text after each trip. <b class="gd-ui">Renters</b> &gt; <b class="gd-ui">Review requests</b> shows the ones on hold and the Google reviews to match.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On hold: the booking has a charge that is not settled or waived yet (late return, kilometres, fuel, cleaning, smoking, damage, tolls) or an open incident. It leaves the list by itself once the charges are settled or waived.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The renter should be asked now anyway? Press <b class="gd-ui">Send anyway</b>. Should never be asked? Press <b class="gd-ui">Do not ask</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Google reviews: a possible match to a renter shows &quot;possible match&quot;. Press <b class="gd-ui">Confirm</b> if it is them, <b class="gd-ui">Not this renter</b> if not, or <b class="gd-ui">Match to a booking</b> with the booking number.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A review that came another way (Turo, a text, a call, email): press <b class="gd-ui">Add a customer review</b> and type the customer&#39;s first name and last initial, the source, the date received, the rating and their words exactly as received, with a screenshot if you have one. It shows on the site with its source. Never write or change a review for a customer.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">On a booking, the card Review requests has <b class="gd-ui">Ask for a review</b> (for example after a call that went well) and <b class="gd-ui">Mark reviewed</b> when the renter says they already left one.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Never offer anything for a review and never ask only happy renters: everyone gets the same message and the same Google link.</div></aside></section><section class="gd-task" id="customer-service-a-change-to-a-confirmed-booking" data-gd-task><h2 class="gd-h2">A change to a confirmed booking</h2><p class="gd-p">On a booking&#39;s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press <b class="gd-ui">Preview the price</b>, then <b class="gd-ui">Send to the renter</b>. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.</p></section><section class="gd-task" id="customer-service-a-late-return" data-gd-task><h2 class="gd-h2">A late return</h2><p class="gd-p">A booking past its return time shows the late return panel. The renter can still extend in their booking while they have the car: the extension counts from the original return time, it is approved at once when the car is free, and paying it stops the late notices. Point them to <b class="gd-ui">Extend</b> first. Otherwise work it in order:</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Button</th><th scope="col">When</th></tr></thead><tbody><tr><td><b class="gd-ui">Log a call</b></td><td>Record each call to the renter and what they said.</td></tr><tr><td><b class="gd-ui">Send T13</b></td><td>The first late notice email.</td></tr><tr><td><b class="gd-ui">Send T14 (final notice)</b></td><td>The final notice.</td></tr><tr><td><b class="gd-ui">Request disable</b></td><td>Ask an Admin to approve disabling the car.</td></tr><tr><td><b class="gd-ui">Open an incident</b></td><td>When the car is not coming back as planned.</td></tr></tbody></table></div></section><section class="gd-task" id="customer-service-booked-when-the-renter-accepts-release-28" data-gd-task><h2 class="gd-h2">Booked when the renter accepts (release 28)</h2><p class="gd-p">A renter who approves the offer has booked the car, even before paying: the booking shows <b class="gd-ui">Booked, payment due</b> and holds the car everywhere. Collect the payment before the pickup (a <b class="gd-ui">Booked, payment due</b> To do comes 48 hours before). When you send an offer, the renter&#39;s view is right under <b class="gd-ui">Send the offer</b>.</p></section><section class="gd-task" id="customer-service-when-a-check-stops-the-pickup-or-the-return-release-33" data-gd-task><h2 class="gd-h2">When a check stops the pickup or the return (release 33)</h2><p class="gd-p">On the booking page, <b class="gd-ui">What stops the pickup now</b> (or the return) lists each check that stops it, in plain words. When the trip must go ahead anyway, press <b class="gd-ui">Ask an Admin to override the pickup</b> (or the return), give the actual time, the km and fuel if you know them, and why. An Admin gets an alert and approves in one tap; the pickup (or the return) is then recorded with the time you entered, and the booking&#39;s history says who asked and who approved. You can cancel your request while it waits. A trip that happened and was never recorded: <b class="gd-ui">Ask to record a past trip</b> with both times; once an Admin approves, the booking lands in Returned so the deposit can be settled.</p></section><section class="gd-task" id="customer-service-book-it-now-release-33" data-gd-task><h2 class="gd-h2">Book it now (release 33)</h2><p class="gd-p">When you send an offer, tick <b class="gd-ui">Book it now (no renter approval)</b> when the renter has already agreed. The offer goes out and an Admin approves it in one tap: the booking then waits for payment, the car is held, and the renter gets one link to sign and pay. You can also have them sign and pay with you: open the booking, <b class="gd-ui">Sign now on this device</b>, then take the card on this device. Already sent the offer? Ask the assistant: &quot;Book the offer of CC-10482 now, the customer agreed by phone&quot;. It shows a card; <b class="gd-ui">Confirm</b> sends the same request to an Admin, who approves in one tap.</p></section><section class="gd-task" id="customer-service-switch-a-booking-between-card-coverage-and-the-protection-pl" data-gd-task><h2 class="gd-h2">Switch a booking between card coverage and the Protection Plan (release 35)</h2><p class="gd-p">When a renter&#39;s card does not cover the car, or they want the plan instead, switch the booking yourself. On the booking page, open the <b class="gd-ui">Coverage</b> card.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Switch to the Protection Plan</b>. You see the plan&#39;s price with HST and the new total before you confirm.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Write the reason (the renter reads it). On a confirmed booking or a rental in progress you can type the plan&#39;s price for this booking, for example for the days left.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press the button. An offer is sent again with the new price. A confirmed booking gets the plan line and the extra is open to collect on the Money tab: Collect sends the pay link. The renter is emailed what changed.</div></li></ol></div><p class="gd-p">The card coverage proof and its review task are cleared for you. <b class="gd-ui">Switch to card coverage</b> puts them back, or gives you a task to get the proof from the renter. Sales switches requests and offers only.</p></section><section class="gd-task" id="customer-service-unanswered" data-gd-task><h2 class="gd-h2">Unanswered</h2><p class="gd-p"><b class="gd-ui">More customer service</b> &gt; <b class="gd-ui">Unanswered</b>: every customer text with no reply and every missed call not called back, oldest first. Reply or call back from the row; <b class="gd-ui">Mark answered</b> when it was answered another way. After 15 minutes the team is alerted. Check WhatsApp by hand each morning.</p></section><section class="gd-task" id="customer-service-the-request-as-sent-and-every-offer-release-35" data-gd-task><h2 class="gd-h2">The request as sent and every offer (release 35)</h2><p class="gd-p">On a request or a booking, <b class="gd-ui">Original request, as the renter sent it</b> shows the car, dates, places, coverage, add-ons, note and the price the renter saw, exactly as sent; staff changes never touch it. <b class="gd-ui">Offer history</b> lists every offer version, newest first: its status, who sent it and when, the car and dates, the message, how the total moved, and the price breakdown.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">To go back to an old version, press <b class="gd-ui">Revert to this offer</b> on it. Its car, dates, price, deposit, discount and fees load into the review as a new offer, highlighted.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the price, then send it in step 3. Nothing changes until you send.</div></li></ol></div><p class="gd-p">The <b class="gd-ui">Coverage</b> line at the top says what the renter chose (own insurance OPCF 27, credit card, Protection Plan) and its proof: not sent yet, waiting for review, confirmed, or rejected with the reason.</p></section><section class="gd-task" id="customer-service-send-an-offer-in-three-steps-release-35" data-gd-task><h2 class="gd-h2">Send an offer in three steps (release 35)</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Car and dates</b>: the renter, the dates, the car and where they pick it up and return it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Price</b>: filled in from the rate sheet with the checkout&#39;s fees and discounts. Change it only if you agreed another price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Review and send</b>: what changed, the message and how the link goes.</div></li></ol></div><p class="gd-p">Rarely used options (billing an insurer, how it is paid, the calendar) are under <b class="gd-ui">More options</b>. Send waits while the price is being worked out again after a date change, and one tap sends once.</p></section><section class="gd-task" id="customer-service-the-owner-s-own-trip-instant-bookings-and-book-it-now-releas" data-gd-task><h2 class="gd-h2">The owner&#39;s own trip, instant bookings and Book it now (release 35)</h2><ul class="gd-ul"><li><b class="gd-ui">Owner&#39;s own trip ($0)</b>: the owner booked their own car. There is nothing to price or send; get the car ready.</li><li><b class="gd-ui">Instant (repeat renter)</b>: a renter with a completed rental, a verified licence and nothing owing booked an available car at once and went straight to sign and pay. An Admin can take a renter&#39;s instant booking away from the booking page.</li><li><b class="gd-ui">Book it now</b> pressed by staff waits for an Admin&#39;s one-tap approval.</li></ul></section><section class="gd-task" id="customer-service-secondary-contact-and-rideshare-documents-release-35" data-gd-task><h2 class="gd-h2">Secondary contact and rideshare documents (release 35)</h2><p class="gd-p">The booking shows the renter&#39;s <b class="gd-ui">Secondary contact</b> when they gave one: call them when the renter cannot be reached. Rideshare and delivery driving are welcome (rental agreement, section 10.3): never tell a renter it is not allowed. When a renter makes <b class="gd-ui">rideshare documents</b> (Uber, Lyft, DoorDash and others), you get an alert and the booking shows the letters they made.</p></section><section class="gd-task" id="customer-service-automatic-answers-release-36" data-gd-task><h2 class="gd-h2">Automatic answers (release 36)</h2><p class="gd-p">Common questions by text, email, WhatsApp, Facebook and Instagram are answered by themselves from the FAQ. <b class="gd-ui">Renter messages</b> &gt; <b class="gd-ui">Automatic answers</b> shows what was answered and what was left for a person. A question the FAQ does not answer stays for you: texts in Messages, emails and Meta messages as a To do, <b class="gd-ui">Answer</b> and the question. Once you text someone, no automatic answer goes to them for 2 hours.</p></section><section class="gd-task" id="customer-service-the-card-the-renter-picked-and-the-two-opcf-27-pages-release" data-gd-task><h2 class="gd-h2">The card the renter picked, and the two OPCF 27 pages (release 35)</h2><p class="gd-p">On <b class="gd-ui">Review documents</b> for a booking:</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Option 2</b>: <b class="gd-ui">Card picked</b> names the card the renter chose from the list (or typed when it was not listed), and <b class="gd-ui">Card check</b> says whether it covers this car: <em>Covers this car</em>, <em>Check it</em> (a card not on the list, a card whose coverage or value limit we do not know, or a car with no value on file) or <em>Does NOT cover this car</em> with the reason. <b class="gd-ui">Approve</b> is refused while the card does not cover the car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Option 1</b>: each page says what it is: <b class="gd-ui">pink slip</b> or <b class="gd-ui">OPCF 27 endorsement</b>. <b class="gd-ui">Approve</b> is refused until both are in. <b class="gd-ui">Reject</b> needs the reason the renter sees.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A renter on OPCF 27 cannot pay until both pages are uploaded, so you see them before the booking is confirmed.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Uploading a renter&#39;s insurance yourself? In <b class="gd-ui">Upload a document</b>, choose <b class="gd-ui">Which page</b>: Pink slip or OPCF 27 endorsement page.</div></aside></section><section class="gd-task" id="customer-service-calls-auto-replies-and-coverage-releases-35-and-36" data-gd-task><h2 class="gd-h2">Calls, auto-replies and coverage (releases 35 and 36)</h2><ul class="gd-ul"><li>Calls from the Call button are recorded; the transcript, summary and Play recording are on the renter&#39;s, lead&#39;s and booking&#39;s history. Quo calls show their transcript and summary there too.</li><li>Automatic answers reply to common questions on every channel from our FAQ. A question they cannot answer becomes your To do: answer it yourself.</li><li>Card coverage: the renter picks their card and the page checks it against the car. Approve OPCF 27 only with both the pink slip and the endorsement page.</li><li>Rideshare and delivery work is allowed with the documents the renter makes on their booking; the secondary contact is on the booking.</li><li>The mid-trip message asks the renter how the trip is going; a problem reported becomes your To do.</li></ul></section><section class="gd-task" id="customer-service-calls-first-texts-after-release-37" data-gd-task><h2 class="gd-h2">Calls first, texts after (release 37)</h2><p class="gd-p">Your main priority is always to be on the phone with people.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Answer a ringing call before anything else, and return a missed call at once.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Call before you text.</b> On a lead, a renter or a booking, <b class="gd-ui">Call</b> is the first button and <b class="gd-ui">Text</b> the second.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A text is a follow-up: after a call attempt (no answer, a voicemail left), or when the person asked for a text.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On your To do and on <b class="gd-ui">Unanswered</b>, missed calls and call-backs are listed above unanswered texts.</div></li></ol></div></section><section class="gd-task" id="customer-service-a-lead-you-handle-on-a-call-release-37" data-gd-task><h2 class="gd-h2">A lead you handle on a call (release 37)</h2><p class="gd-p">When you answer or place a call with a lead, add a note on it, or create it from a call, the lead is yours for a limited time (15 minutes, as a Sales claim; an Admin can change it in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Sales</b>). Every call you handle adds the time again.</p><ul class="gd-ul"><li>Sales see <b class="gd-ui">Being handled by</b> your first name and your function with the time, on the lead and in every list. They cannot claim it, call, text or email it, or set an outcome meanwhile, and <b class="gd-ui">Next lead</b> skips it.</li><li>Another customer service or Fleet person can still work it; their call or note takes the hold over.</li><li>When it ends, the lead goes back to the salesperson who had a claim on it or who brought it, else to the open list. An Admin can <b class="gd-ui">Release hold</b> earlier.</li><li>A booking made from the lead is credited as always: customer service and Fleet get no sales commission for it.</li><li>Nobody who has not finished onboarding holds a lead.</li></ul></section><section class="gd-task" id="customer-service-the-person-behind-the-lead-release-40" data-gd-task><h2 class="gd-h2">The person behind the lead (release 40)</h2><p class="gd-p">On <b class="gd-ui">Leads</b>, press <b class="gd-ui">The person</b> on a card, or open the lead, to see the whole person: contact, account and licence verified (yes or no), bookings and balances, deposit, requests and offers, earlier leads, messages, calls and texts, notes, reviews, incidents, who has handled them, and the <b class="gd-ui">Signals</b> timeline of everything they did with us. Outside the renter&#39;s window you see it in full while you hold the lead on a call; otherwise you see the contact and account.</p></section>');
select app.guide_release_section('va', 'sales', 'chapter', 'fleet', 'You turn enquiries into bookings and owners into fleet: requests and offers, quotes for callers, and owner leads.

Your menu: To do, Today, My scorecard and My sales, then Requests and offers, Send an offer, Add a rental, New quote, Calendar and Buyer leads. The owners you bring in are on My sales.

## Requests, offers and new quotes

1. **Requests and offers**: the same queue customer service works, showing only what you can answer now. A request still with customer service is folded under "more not open to you yet", with the time it opens to you.
2. **Rentals** > **Bookings**: **My bookings**, every booking credited to you, offered by you or added by you, from the offer to the return, with its status, money and your commission (counting this month, waiting for approval, approved, paid).
3. **Send an offer**: one screen for a caller, sent at once, as in chapter 2. **New quote** still makes a request to offer later.
3. An offer that is out: **More actions** > **Edit the offer**, then **Save and send the update**.

![](/guides/img/va-sales-02-requests-desktop-2ab1d17d.jpg "desktop; size: 1230 580; address: carmacars.ca/va/requests; pins: 1 39.8 59.5")

> Tip: Your first reply target is 5 minutes, the "Quote sent" measure on your scorecard. Follow every offer out before it expires.

## Check the renter''s licence

Sales approve the renter''s licence like customer service: the licence front, the licence back and the selfie. The proof of coverage and the Protection Plan stay with customer service and Admins.

1. On **To do**, **Licences to check** lists each booking with an image waiting, the longest wait first. Press **Review the licence**.
2. On a booking, the card **Renter licence** has the same: press **Review the licence**.
3. Look at each image and each Flag line of the licence reader under the driver: no alteration, the selfie matches the licence photo.
4. One is wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**. The renter is told and asked for a new image.
5. Then press **Approve all**: every image still waiting is approved at once. An image the system refuses is named with the reason.

> Tip: The booking history says who decided and the role, sales. Each opening of the images is logged and the links last one minute.

## In person or remote

Every Sales person works in one of two modes, on the same Sales screens. An Admin sets yours; it shows at the top of To do and on My sales.

|  | In person (Toronto) | Remote (anywhere) |
| --- | --- | --- |
| Commission | Under 50 rental days in the month 10%, from 50 days 15%, from 100 days 20% | Under 50 rental days 5%, from 50 days 10%, from 100 days 15% |
| Credit | Walk-ins, handovers you close, partner visits and the rentals you source | Only the rentals you source. A website request you answer with the first offer during one of your blocks counts as yours. Walk-ins and partner deals earn nothing |
| Hours | You choose | At least 20 hours a week of Thursday to Sunday afternoons (noon to 6 pm, Toronto time), replying within 15 minutes to the chats, texts and calls assigned to you |
| Every day | Nothing set | Marketplace and classified reposts, social media DM replies, three follow-ups on every quote, long-term and business outreach |
| Every month | Nothing set | 400 touches. Under 400 when the month ends, the month''s rate is one tier lower: 15% becomes 10%, 10% becomes 5%, 5% becomes 2.5% |

## Remote: your duties

On **To do**, **Remote duties** shows this month''s touches against 400, today''s checklist, the peak hours you scheduled this week and your reply time.

1. Most touches count by themselves: an offer you send, a message or text you send from the portal, a live chat you answer (once a day for each chat), a call or text from the phone line, an ad you post, a call or message to a car owner.
2. For anything else press **Log a touch**: choose the type and add the link of the post, profile or listing if there is one.
3. The checklist ticks itself as the day''s touches come in. Three follow-ups on every quote stays open while a deal of yours has fewer than three.
4. Under My availability choose this week or next, press **Add a block** for each time you will be on, then **Save the week**. Days already past stay as they were.
5. A website request you answer with the first offer during a block is credited to you as sourced, even if you chose Entered for CarmaCars. Off your blocks it stays a claim for an Admin.

> Tip: An Admin can void a touch logged by mistake. Once an Admin approves a month, its mode, its rates and its touches no longer change; a refund can still lower the tier, as for everyone.

## My sales

Open **Me**, the **My sales** tab. It shows your own sales and commissions only.

1. Commissions comes first. Your rate depends on your mode and the rental days of the month: in person 10%, 15% from 50 days, 20% from 100; remote 5%, 10% and 15%. The bar shows your days against the target of 100, and says when your rate rises. By month gives each month in one line: the mode, the days, the rate and, for remote, the touches and any drop.
2. The tiles show this week: quotes created, offers sent, rentals added, bookings confirmed, conversion, booked revenue and follow-ups due. Press **By month** for months, **By week** for weeks.
3. By week (or By month) lists each period with the same figures, newest first.
4. Follow-ups due lists your open deals with what to do next: send the offer, follow up before the offer expires, or follow up while the renter signs and pays. Red means it is past due.
5. Deals lists every booking you created, added or sent an offer on in the last 180 days, with its status and what it counts. Open a request, an offer or a rental you added from its number.

| Figure | How it is counted |
| --- | --- |
| Credited to you | A quote you created, a rental you added, or a website request whose first offer you sent. An Admin can give a deal to someone else. |
| Quotes created, offers sent, rentals added | Counted on the day they happened. |
| Bookings confirmed, booked revenue | Counted on the day the booking was confirmed. |
| Conversion | Of the deals credited to you in the period, the share confirmed so far. |
| Booked revenue | The rental charge before tax, after discounts. A cancelled booking counts only what was kept; refunds come off. |
| Rental days (Sales) | The days of the completed, paid rentals you sourced that end in the month. The month''s tier applies to all of that month''s rentals. |

> Tip: Sales commissions are approved after the month ends, when the month''s tier is known. A refund that drops the month under a tier lowers every commission of that month; anything already paid comes off your next payment.

## Owners you bring in

Bring in car owners on **My work** > **My sales**, card **Owners you bring in**. Every owner you bring in is credited to you as "sourced by", with their cars. Only an Admin can change that later.

1. **Invite an owner**: enter their name, email and phone, tick **The owner asked me to send it**, then press **Send the invitation**. They get an email with your link to apply.
2. **Copy my owner link**: your own link to the application, for a message or a post. Anyone who applies with it is credited to you.
3. **Start an application**: you fill in the owner and the car for them, with **Take a photo** (or **Choose a photo**) of the ownership permit to fill in the car. It goes to an Admin as an application to approve. The terms and invoices are the Admin''s. A corporation that leases its cars to CarmaCars: choose **A corporation**, then Route **Fleet supplier: leases the cars to CarmaCars**, and each car''s tier (**Regular** or **Troubled**). A fleet supplier can also apply himself from `carmacars.ca/list-your-car`: your owner link works for it too.
4. The row of five figures follows your owners: **Invited**, **Applied**, **Approved**, **Car live** and **First paid rental**. Below, each owner shows their stage and their cars.

5. Someone who starts the application on the website and stops for 30 minutes comes to you: a task "Unfinished owner application" and their row on My sales (Lead). Call or text them; the follow-up emails go by themselves until they finish.

> Tip: An owner already on file, or invited first by another salesperson, cannot be invited again. Ask an Admin if you brought them in.

## Ask for your commission on an owner

There is no set amount. For each owner you bring in, you ask for one, and an Admin decides.

1. On the owner''s row press **Ask for a commission**.
2. Choose **A flat amount** and type it, or **A percent**: type the percent, choose what it is of (the company''s share of their cars'' rentals, or their cars'' rental revenue) and for how long (a number of months, or as long as the car is with us).
3. Add a note for the Admin if you like, then press **Send to an Admin**.
4. While it waits you can press **Change my request**. Once an Admin approves, changes or declines it, the row says so, with their note.

| Approved as | When it is earned |
| --- | --- |
| A flat amount | Once, at the owner''s first paid rental: the first completed rental of any of their cars, paid in full |
| A percent | On each completed, paid rental of their cars that ends after the approval, from the month of the first one, for the months approved |

> Tip: Nothing is earned before an Admin approves the request, and nothing on CarmaCars'' own cars, a partner''s, a shareholder''s or your own. Each commission then goes through the usual steps on My sales: pending approval, approved, paid.

## Buyer leads

1. **Buyer leads**: each request from the /buy pages, with the car, budget and timing.
2. Press **Take it** to make it yours, then call them.
3. Press **Update** to set the status. When you close a lead, say why.

> Tip: Owner leads are not here. The owners you invite or add are on **My sales**, **Owners you bring in**, and you see only your own. Customer service works the full owner pipeline.

An offer that has been expired for 7 days leaves Requests and offers and becomes a renter lead: you get the To do "Expired offer: win the renter back" (the lead goes to the Sales person with the fewest open leads) with the renter''s contact, the car and the dates they wanted. Call or text them, then mark the lead contacted or closed.

**Reopen offer** on an expired booking (or the **Expired** filter of Requests) sends the offer again in one click, open 24 hours unless you set the hours; a pickup time that has passed asks for new dates first. "Renter wants expired offer reopened" To dos come from the renter''s own button. The offer screens block **Send** with **Pickup time has passed: update it** until the pickup is moved.

## Book it now (release 33)
When you send an offer, tick **Book it now (no renter approval)** when the renter has already agreed. The offer goes out and an Admin approves it in one tap: the booking then waits for payment, the car is held, and the renter gets one link to sign and pay. You can also have them sign and pay with you: open the booking, **Sign now on this device**, then take the card on this device.
Already sent the offer? Ask the assistant: "Book the offer of CC-10482 now, the customer agreed by phone". It shows a card; **Confirm** sends the same request to an Admin, who approves in one tap.

## When a check stops the pickup or the return (release 33)
On the booking page, **What stops the pickup now** (or the return) lists each check that stops it, in plain words. When the trip must go ahead anyway, press **Ask an Admin to override the pickup** (or the return), give the actual time, the km and fuel if you know them, and why. An Admin gets an alert and approves in one tap; the pickup (or the return) is then recorded with the time you entered, and the booking''s history says who asked and who approved. You can cancel your request while it waits. A trip that happened and was never recorded: **Ask to record a past trip** with both times; once an Admin approves, the booking lands in Returned so the deposit can be settled.

## Leads and claims

Open **Leads**. Every lead is there: renter leads (forms, live chat, the phone number box, games, expired offers, requests not sent, missed calls, Live visitors), owner leads and partner leads, new and hot first. A new-lead alert on your phone opens that lead.

1. Press **Next lead**, or **Claim** on a card. The lead is yours for 15 minutes.
2. Press **Call**, **Text** or **Email**: your phone or mail app opens and the contact is logged. Each contact (or **Note**) adds 15 minutes, up to 60 minutes from your claim.
3. Press **Outcome**: Contacted, Call booked, Applied, Won or Lost (say why). Or **Mark handled** when there is nothing more to do.
4. Can''t finish? Press **Unclaim** so someone else can take it. A claim that runs out goes back to the pool by itself.

You hold at most 25 leads at once. Your numbers are on To do under **My leads**: leads claimed, won, close rate (won out of claimed), contacted, time to first contact and claims that ran out, today, this week and this month. Owner leads are also under **Owners** > **Leads**.
## Call minutes (release 35)
Your home shows **My call minutes**: today, this week and this month, for connected calls made with the site''s **Call** button. Customer numbers are hidden for Sales; call and text with the buttons on the page.


## Get a renter ready for the pickup (release 35)
Your work does not stop at the offer. Until the car is handed over you can do everything that gets the renter good to go:
- **Payment**: send a pay link or a deposit link on Money (text or email), or take the card on this device, also on a confirmed booking.
- **The offer**: edit it, send it again with a later expiry, withdraw it or record that the renter approved by phone, also while it waits for payment.
- **ID and coverage**: approve or reject the licence, the selfie and the proof of coverage, with the reason the renter sees.
- **Drivers and agreement**: send each additional driver their signing link, or the agreement again.
- **Name change asked for**: when a verified renter asks for a name or date of birth correction, it shows on the booking; check it against the licence, then **Approve** or **Decline**.

The booking page shows **Ready for the rental**: one line for each thing the pickup needs (offer accepted, paid, licence and selfie, coverage, deposit, drivers, agreement, add-ons in the car), green when done, with what to press when not. Refunds, cancellations, deposit releases and removing a paid add-on stay with customer service, Finance and Admins.

## The Prepare checklist (release 35)
On a booking with add-ons, **Prepare for the pickup** shows each add-on with its quantity, ticked or not by field staff, who ticked it and when, and the pickup or delivery job with its field person. It is on the booking and on the car page, for Sales, customer service, Fleet and Finance.

## Rebooking, intent and offers (release 35)

- A returning renter''s new request comes straight to you when you had their last booking, with the usual claim time.
- Each lead shows its intent (hot, warm or cold) and what the person said they want, read from calls with their transcripts, texts, emails, chat and visits. Call hot leads first.
- Offers are three steps: car and dates, price, review and send. Every version is kept; you can load an old one as a new offer.
- Prices stay between the owner''s daily minimum and maximum; only an Admin allows one outside them.
- Repeat renters who are verified can book instantly; their booking is marked Instant (repeat renter).
- Rewards: tell renters they earn points for a photo with their review and every rental after the first.

## Calls first, texts after (release 37)

Your main priority is always to be on the phone with people.

1. Answer a ringing call before anything else, and return a missed call at once.
2. **Call before you text.** On a lead, a renter or a booking, **Call** is the first button and **Text** the second.
3. A text is a follow-up: after a call attempt (no answer, a voicemail left), or when the person asked for a text.
4. On your To do and on **Unanswered**, missed calls and call-backs are listed above unanswered texts.

## A lead customer service is handling (release 37)

When customer service or Fleet are on a call with a lead, the lead and the lists say **Being handled by** their first name, their function and the time. Leave it alone: you cannot claim it, call, text or email it, or set an outcome, and **Next lead** skips it. When their time ends, the lead returns to you if you had a claim on it or brought it, else to the open list. The booking credit rules do not change.', 'Sales', 'Requests and offers, new quotes and owner leads.',
  'You turn enquiries into bookings and owners into fleet: requests and offers, quotes for callers, and owner leads.

Your menu: To do, Today, My scorecard and My sales, then Requests and offers, Send an offer, Add a rental, New quote, Calendar and Buyer leads. The owners you bring in are on My sales.

## Requests, offers and new quotes

1. **Requests and offers**: the same queue customer service works, showing only what you can answer now. A request still with customer service is folded under "more not open to you yet", with the time it opens to you.
2. **Rentals** > **Bookings**: **My bookings**, every booking credited to you, offered by you or added by you, from the offer to the return, with its status, money and your commission (counting this month, waiting for approval, approved, paid).
3. **Send an offer**: one screen for a caller, sent at once, as in chapter 2. **New quote** still makes a request to offer later.
3. An offer that is out: **More actions** > **Edit the offer**, then **Save and send the update**.

![](/guides/img/va-sales-02-requests-desktop-2ab1d17d.jpg "desktop; size: 1230 580; address: carmacars.ca/va/requests; pins: 1 39.8 59.5")

> Tip: Your first reply target is 5 minutes, the "Quote sent" measure on your scorecard. Follow every offer out before it expires.

## Check the renter''s licence

Sales approve the renter''s licence like customer service: the licence front, the licence back and the selfie. The proof of coverage and the Protection Plan stay with customer service and Admins.

1. On **To do**, **Licences to check** lists each booking with an image waiting, the longest wait first. Press **Review the licence**.
2. On a booking, the card **Renter licence** has the same: press **Review the licence**.
3. Look at each image and each Flag line of the licence reader under the driver: no alteration, the selfie matches the licence photo.
4. One is wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**. The renter is told and asked for a new image.
5. Then press **Approve all**: every image still waiting is approved at once. An image the system refuses is named with the reason.

> Tip: The booking history says who decided and the role, sales. Each opening of the images is logged and the links last one minute.

## In person or remote

Every Sales person works in one of two modes, on the same Sales screens. An Admin sets yours; it shows at the top of To do and on My sales.

|  | In person (Toronto) | Remote (anywhere) |
| --- | --- | --- |
| Commission | Under 50 rental days in the month 10%, from 50 days 15%, from 100 days 20% | Under 50 rental days 5%, from 50 days 10%, from 100 days 15% |
| Credit | Walk-ins, handovers you close, partner visits and the rentals you source | Only the rentals you source. A website request you answer with the first offer during one of your blocks counts as yours. Walk-ins and partner deals earn nothing |
| Hours | You choose | At least 20 hours a week of Thursday to Sunday afternoons (noon to 6 pm, Toronto time), replying within 15 minutes to the chats, texts and calls assigned to you |
| Every day | Nothing set | Marketplace and classified reposts, social media DM replies, three follow-ups on every quote, long-term and business outreach |
| Every month | Nothing set | 400 touches. Under 400 when the month ends, the month''s rate is one tier lower: 15% becomes 10%, 10% becomes 5%, 5% becomes 2.5% |

## Remote: your duties

On **To do**, **Remote duties** shows this month''s touches against 400, today''s checklist, the peak hours you scheduled this week and your reply time.

1. Most touches count by themselves: an offer you send, a message or text you send from the portal, a live chat you answer (once a day for each chat), a call or text from the phone line, an ad you post, a call or message to a car owner.
2. For anything else press **Log a touch**: choose the type and add the link of the post, profile or listing if there is one.
3. The checklist ticks itself as the day''s touches come in. Three follow-ups on every quote stays open while a deal of yours has fewer than three.
4. Under My availability choose this week or next, press **Add a block** for each time you will be on, then **Save the week**. Days already past stay as they were.
5. A website request you answer with the first offer during a block is credited to you as sourced, even if you chose Entered for CarmaCars. Off your blocks it stays a claim for an Admin.

> Tip: An Admin can void a touch logged by mistake. Once an Admin approves a month, its mode, its rates and its touches no longer change; a refund can still lower the tier, as for everyone.

## My sales

Open **Me**, the **My sales** tab. It shows your own sales and commissions only.

1. Commissions comes first. Your rate depends on your mode and the rental days of the month: in person 10%, 15% from 50 days, 20% from 100; remote 5%, 10% and 15%. The bar shows your days against the target of 100, and says when your rate rises. By month gives each month in one line: the mode, the days, the rate and, for remote, the touches and any drop.
2. The tiles show this week: quotes created, offers sent, rentals added, bookings confirmed, conversion, booked revenue and follow-ups due. Press **By month** for months, **By week** for weeks.
3. By week (or By month) lists each period with the same figures, newest first.
4. Follow-ups due lists your open deals with what to do next: send the offer, follow up before the offer expires, or follow up while the renter signs and pays. Red means it is past due.
5. Deals lists every booking you created, added or sent an offer on in the last 180 days, with its status and what it counts. Open a request, an offer or a rental you added from its number.

| Figure | How it is counted |
| --- | --- |
| Credited to you | A quote you created, a rental you added, or a website request whose first offer you sent. An Admin can give a deal to someone else. |
| Quotes created, offers sent, rentals added | Counted on the day they happened. |
| Bookings confirmed, booked revenue | Counted on the day the booking was confirmed. |
| Conversion | Of the deals credited to you in the period, the share confirmed so far. |
| Booked revenue | The rental charge before tax, after discounts. A cancelled booking counts only what was kept; refunds come off. |
| Rental days (Sales) | The days of the completed, paid rentals you sourced that end in the month. The month''s tier applies to all of that month''s rentals. |

> Tip: Sales commissions are approved after the month ends, when the month''s tier is known. A refund that drops the month under a tier lowers every commission of that month; anything already paid comes off your next payment.

## Owners you bring in

Bring in car owners on **My work** > **My sales**, card **Owners you bring in**. Every owner you bring in is credited to you as "sourced by", with their cars. Only an Admin can change that later.

1. **Invite an owner**: enter their name, email and phone, tick **The owner asked me to send it**, then press **Send the invitation**. They get an email with your link to apply.
2. **Copy my owner link**: your own link to the application, for a message or a post. Anyone who applies with it is credited to you.
3. **Start an application**: you fill in the owner and the car for them, with **Take a photo** (or **Choose a photo**) of the ownership permit to fill in the car. It goes to an Admin as an application to approve. The terms and invoices are the Admin''s. A corporation that leases its cars to CarmaCars: choose **A corporation**, then Route **Fleet supplier: leases the cars to CarmaCars**, and each car''s tier (**Regular** or **Troubled**). A fleet supplier can also apply himself from `carmacars.ca/list-your-car`: your owner link works for it too.
4. The row of five figures follows your owners: **Invited**, **Applied**, **Approved**, **Car live** and **First paid rental**. Below, each owner shows their stage and their cars.

5. Someone who starts the application on the website and stops for 30 minutes comes to you: a task "Unfinished owner application" and their row on My sales (Lead). Call or text them; the follow-up emails go by themselves until they finish.

> Tip: An owner already on file, or invited first by another salesperson, cannot be invited again. Ask an Admin if you brought them in.

## Ask for your commission on an owner

There is no set amount. For each owner you bring in, you ask for one, and an Admin decides.

1. On the owner''s row press **Ask for a commission**.
2. Choose **A flat amount** and type it, or **A percent**: type the percent, choose what it is of (the company''s share of their cars'' rentals, or their cars'' rental revenue) and for how long (a number of months, or as long as the car is with us).
3. Add a note for the Admin if you like, then press **Send to an Admin**.
4. While it waits you can press **Change my request**. Once an Admin approves, changes or declines it, the row says so, with their note.

| Approved as | When it is earned |
| --- | --- |
| A flat amount | Once, at the owner''s first paid rental: the first completed rental of any of their cars, paid in full |
| A percent | On each completed, paid rental of their cars that ends after the approval, from the month of the first one, for the months approved |

> Tip: Nothing is earned before an Admin approves the request, and nothing on CarmaCars'' own cars, a partner''s, a shareholder''s or your own. Each commission then goes through the usual steps on My sales: pending approval, approved, paid.

## Buyer leads

1. **Buyer leads**: each request from the /buy pages, with the car, budget and timing.
2. Press **Take it** to make it yours, then call them.
3. Press **Update** to set the status. When you close a lead, say why.

> Tip: Owner leads are not here. The owners you invite or add are on **My sales**, **Owners you bring in**, and you see only your own. Customer service works the full owner pipeline.

An offer that has been expired for 7 days leaves Requests and offers and becomes a renter lead: you get the To do "Expired offer: win the renter back" (the lead goes to the Sales person with the fewest open leads) with the renter''s contact, the car and the dates they wanted. Call or text them, then mark the lead contacted or closed.

**Reopen offer** on an expired booking (or the **Expired** filter of Requests) sends the offer again in one click, open 24 hours unless you set the hours; a pickup time that has passed asks for new dates first. "Renter wants expired offer reopened" To dos come from the renter''s own button. The offer screens block **Send** with **Pickup time has passed: update it** until the pickup is moved.

## Book it now (release 33)
When you send an offer, tick **Book it now (no renter approval)** when the renter has already agreed. The offer goes out and an Admin approves it in one tap: the booking then waits for payment, the car is held, and the renter gets one link to sign and pay. You can also have them sign and pay with you: open the booking, **Sign now on this device**, then take the card on this device.
Already sent the offer? Ask the assistant: "Book the offer of CC-10482 now, the customer agreed by phone". It shows a card; **Confirm** sends the same request to an Admin, who approves in one tap.

## When a check stops the pickup or the return (release 33)
On the booking page, **What stops the pickup now** (or the return) lists each check that stops it, in plain words. When the trip must go ahead anyway, press **Ask an Admin to override the pickup** (or the return), give the actual time, the km and fuel if you know them, and why. An Admin gets an alert and approves in one tap; the pickup (or the return) is then recorded with the time you entered, and the booking''s history says who asked and who approved. You can cancel your request while it waits. A trip that happened and was never recorded: **Ask to record a past trip** with both times; once an Admin approves, the booking lands in Returned so the deposit can be settled.

## Leads and claims

Open **Leads**. Every lead is there: renter leads (forms, live chat, the phone number box, games, expired offers, requests not sent, missed calls, Live visitors), owner leads and partner leads, new and hot first. A new-lead alert on your phone opens that lead.

1. Press **Next lead**, or **Claim** on a card. The lead is yours for 15 minutes.
2. Press **Call**, **Text** or **Email**: your phone or mail app opens and the contact is logged. Each contact (or **Note**) adds 15 minutes, up to 60 minutes from your claim.
3. Press **Outcome**: Contacted, Call booked, Applied, Won or Lost (say why). Or **Mark handled** when there is nothing more to do.
4. Can''t finish? Press **Unclaim** so someone else can take it. A claim that runs out goes back to the pool by itself.

You hold at most 25 leads at once. Your numbers are on To do under **My leads**: leads claimed, won, close rate (won out of claimed), contacted, time to first contact and claims that ran out, today, this week and this month. Owner leads are also under **Owners** > **Leads**.

## The person behind the lead (release 40)

Press **The person** on a lead card, or open the lead, to see everything we know about them in one place: their name and the name they go by, phone and email, account and whether the licence is verified (yes or no, never the number), every booking with the car, dates, status, total and anything owed, the deposit, open requests and offers sent, their earlier leads, messages, calls and texts, notes, reviews, incidents, and who has handled them. **Signals** lists everything they did with us, newest first: calls and texts, WhatsApp, chat, emails, visits, cars and offers looked at, bookings and reviews. The intent score counts all of it.

When the renter is outside your window, you see their contact and account until the lead is yours: claim it (or an Admin assigns it to you) and the rest opens, logged as a record you opened for a reason. An Admin can assign leads to you in bulk: they show **Assigned to you by an Admin**, do not run out, and do not count against your limit of open leads.
## Call minutes (release 35)
Your home shows **My call minutes**: today, this week and this month, for connected calls made with the site''s **Call** button. Customer numbers are hidden for Sales; call and text with the buttons on the page.


## Get a renter ready for the pickup (release 35)
Your work does not stop at the offer. Until the car is handed over you can do everything that gets the renter good to go:
- **Payment**: send a pay link or a deposit link on Money (text or email), or take the card on this device, also on a confirmed booking.
- **The offer**: edit it, send it again with a later expiry, withdraw it or record that the renter approved by phone, also while it waits for payment.
- **ID and coverage**: approve or reject the licence, the selfie and the proof of coverage, with the reason the renter sees.
- **Drivers and agreement**: send each additional driver their signing link, or the agreement again.
- **Name change asked for**: when a verified renter asks for a name or date of birth correction, it shows on the booking; check it against the licence, then **Approve** or **Decline**.

The booking page shows **Ready for the rental**: one line for each thing the pickup needs (offer accepted, paid, licence and selfie, coverage, deposit, drivers, agreement, add-ons in the car), green when done, with what to press when not. Refunds, cancellations, deposit releases and removing a paid add-on stay with customer service, Finance and Admins.

## The Prepare checklist (release 35)
On a booking with add-ons, **Prepare for the pickup** shows each add-on with its quantity, ticked or not by field staff, who ticked it and when, and the pickup or delivery job with its field person. It is on the booking and on the car page, for Sales, customer service, Fleet and Finance.

## Rebooking, intent and offers (release 35)

- A returning renter''s new request comes straight to you when you had their last booking, with the usual claim time.
- Each lead shows its intent (hot, warm or cold) and what the person said they want, read from calls with their transcripts, texts, emails, chat and visits. Call hot leads first.
- Offers are three steps: car and dates, price, review and send. Every version is kept; you can load an old one as a new offer.
- Prices stay between the owner''s daily minimum and maximum; only an Admin allows one outside them.
- Repeat renters who are verified can book instantly; their booking is marked Instant (repeat renter).
- Rewards: tell renters they earn points for a photo with their review and every rental after the first.

## Calls first, texts after (release 37)

Your main priority is always to be on the phone with people.

1. Answer a ringing call before anything else, and return a missed call at once.
2. **Call before you text.** On a lead, a renter or a booking, **Call** is the first button and **Text** the second.
3. A text is a follow-up: after a call attempt (no answer, a voicemail left), or when the person asked for a text.
4. On your To do and on **Unanswered**, missed calls and call-backs are listed above unanswered texts.

## A lead customer service is handling (release 37)

When customer service or Fleet are on a call with a lead, the lead and the lists say **Being handled by** their first name, their function and the time. Leave it alone: you cannot claim it, call, text or email it, or set an outcome, and **Next lead** skips it. When their time ends, the lead returns to you if you had a claim on it or brought it, else to the open list. The booking credit rules do not change.',
  '<p class="gd-p">You turn enquiries into bookings and owners into fleet: requests and offers, quotes for callers, and owner leads.</p><p class="gd-p">Your menu: To do, Today, My scorecard and My sales, then Requests and offers, Send an offer, Add a rental, New quote, Calendar and Buyer leads. The owners you bring in are on My sales.</p><section class="gd-task" id="sales-requests-offers-and-new-quotes" data-gd-task><h2 class="gd-h2">Requests, offers and new quotes</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Requests and offers</b>: the same queue customer service works, showing only what you can answer now. A request still with customer service is folded under &quot;more not open to you yet&quot;, with the time it opens to you.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Rentals</b> &gt; <b class="gd-ui">Bookings</b>: <b class="gd-ui">My bookings</b>, every booking credited to you, offered by you or added by you, from the offer to the return, with its status, money and your commission (counting this month, waiting for approval, approved, paid).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Send an offer</b>: one screen for a caller, sent at once, as in chapter 2. <b class="gd-ui">New quote</b> still makes a request to offer later.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">An offer that is out: <b class="gd-ui">More actions</b> &gt; <b class="gd-ui">Edit the offer</b>, then <b class="gd-ui">Save and send the update</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/580"><img src="/guides/img/va-sales-02-requests-desktop-2ab1d17d.jpg" alt="" loading="lazy" decoding="async" width="1230" height="580"><span class="gd-pin" style="left:39.8%;top:59.5%" aria-hidden="true">1</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Your first reply target is 5 minutes, the &quot;Quote sent&quot; measure on your scorecard. Follow every offer out before it expires.</div></aside></section><section class="gd-task" id="sales-check-the-renter-s-licence" data-gd-task><h2 class="gd-h2">Check the renter&#39;s licence</h2><p class="gd-p">Sales approve the renter&#39;s licence like customer service: the licence front, the licence back and the selfie. The proof of coverage and the Protection Plan stay with customer service and Admins.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On <b class="gd-ui">To do</b>, <b class="gd-ui">Licences to check</b> lists each booking with an image waiting, the longest wait first. Press <b class="gd-ui">Review the licence</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">On a booking, the card <b class="gd-ui">Renter licence</b> has the same: press <b class="gd-ui">Review the licence</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Look at each image and each Flag line of the licence reader under the driver: no alteration, the selfie matches the licence photo.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">One is wrong? Open <b class="gd-ui">Reject this one</b> under it, type the reason the renter reads and press <b class="gd-ui">Reject</b>. The renter is told and asked for a new image.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Then press <b class="gd-ui">Approve all</b>: every image still waiting is approved at once. An image the system refuses is named with the reason.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The booking history says who decided and the role, sales. Each opening of the images is logged and the links last one minute.</div></aside></section><section class="gd-task" id="sales-in-person-or-remote" data-gd-task><h2 class="gd-h2">In person or remote</h2><p class="gd-p">Every Sales person works in one of two modes, on the same Sales screens. An Admin sets yours; it shows at the top of To do and on My sales.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col"></th><th scope="col">In person (Toronto)</th><th scope="col">Remote (anywhere)</th></tr></thead><tbody><tr><td>Commission</td><td>Under 50 rental days in the month 10%, from 50 days 15%, from 100 days 20%</td><td>Under 50 rental days 5%, from 50 days 10%, from 100 days 15%</td></tr><tr><td>Credit</td><td>Walk-ins, handovers you close, partner visits and the rentals you source</td><td>Only the rentals you source. A website request you answer with the first offer during one of your blocks counts as yours. Walk-ins and partner deals earn nothing</td></tr><tr><td>Hours</td><td>You choose</td><td>At least 20 hours a week of Thursday to Sunday afternoons (noon to 6 pm, Toronto time), replying within 15 minutes to the chats, texts and calls assigned to you</td></tr><tr><td>Every day</td><td>Nothing set</td><td>Marketplace and classified reposts, social media DM replies, three follow-ups on every quote, long-term and business outreach</td></tr><tr><td>Every month</td><td>Nothing set</td><td>400 touches. Under 400 when the month ends, the month&#39;s rate is one tier lower: 15% becomes 10%, 10% becomes 5%, 5% becomes 2.5%</td></tr></tbody></table></div></section><section class="gd-task" id="sales-remote-your-duties" data-gd-task><h2 class="gd-h2">Remote: your duties</h2><p class="gd-p">On <b class="gd-ui">To do</b>, <b class="gd-ui">Remote duties</b> shows this month&#39;s touches against 400, today&#39;s checklist, the peak hours you scheduled this week and your reply time.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Most touches count by themselves: an offer you send, a message or text you send from the portal, a live chat you answer (once a day for each chat), a call or text from the phone line, an ad you post, a call or message to a car owner.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">For anything else press <b class="gd-ui">Log a touch</b>: choose the type and add the link of the post, profile or listing if there is one.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The checklist ticks itself as the day&#39;s touches come in. Three follow-ups on every quote stays open while a deal of yours has fewer than three.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Under My availability choose this week or next, press <b class="gd-ui">Add a block</b> for each time you will be on, then <b class="gd-ui">Save the week</b>. Days already past stay as they were.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A website request you answer with the first offer during a block is credited to you as sourced, even if you chose Entered for CarmaCars. Off your blocks it stays a claim for an Admin.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>An Admin can void a touch logged by mistake. Once an Admin approves a month, its mode, its rates and its touches no longer change; a refund can still lower the tier, as for everyone.</div></aside></section><section class="gd-task" id="sales-my-sales" data-gd-task><h2 class="gd-h2">My sales</h2><p class="gd-p">Open <b class="gd-ui">Me</b>, the <b class="gd-ui">My sales</b> tab. It shows your own sales and commissions only.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Commissions comes first. Your rate depends on your mode and the rental days of the month: in person 10%, 15% from 50 days, 20% from 100; remote 5%, 10% and 15%. The bar shows your days against the target of 100, and says when your rate rises. By month gives each month in one line: the mode, the days, the rate and, for remote, the touches and any drop.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The tiles show this week: quotes created, offers sent, rentals added, bookings confirmed, conversion, booked revenue and follow-ups due. Press <b class="gd-ui">By month</b> for months, <b class="gd-ui">By week</b> for weeks.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">By week (or By month) lists each period with the same figures, newest first.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Follow-ups due lists your open deals with what to do next: send the offer, follow up before the offer expires, or follow up while the renter signs and pays. Red means it is past due.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Deals lists every booking you created, added or sent an offer on in the last 180 days, with its status and what it counts. Open a request, an offer or a rental you added from its number.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Figure</th><th scope="col">How it is counted</th></tr></thead><tbody><tr><td>Credited to you</td><td>A quote you created, a rental you added, or a website request whose first offer you sent. An Admin can give a deal to someone else.</td></tr><tr><td>Quotes created, offers sent, rentals added</td><td>Counted on the day they happened.</td></tr><tr><td>Bookings confirmed, booked revenue</td><td>Counted on the day the booking was confirmed.</td></tr><tr><td>Conversion</td><td>Of the deals credited to you in the period, the share confirmed so far.</td></tr><tr><td>Booked revenue</td><td>The rental charge before tax, after discounts. A cancelled booking counts only what was kept; refunds come off.</td></tr><tr><td>Rental days (Sales)</td><td>The days of the completed, paid rentals you sourced that end in the month. The month&#39;s tier applies to all of that month&#39;s rentals.</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Sales commissions are approved after the month ends, when the month&#39;s tier is known. A refund that drops the month under a tier lowers every commission of that month; anything already paid comes off your next payment.</div></aside></section><section class="gd-task" id="sales-owners-you-bring-in" data-gd-task><h2 class="gd-h2">Owners you bring in</h2><p class="gd-p">Bring in car owners on <b class="gd-ui">My work</b> &gt; <b class="gd-ui">My sales</b>, card <b class="gd-ui">Owners you bring in</b>. Every owner you bring in is credited to you as &quot;sourced by&quot;, with their cars. Only an Admin can change that later.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Invite an owner</b>: enter their name, email and phone, tick <b class="gd-ui">The owner asked me to send it</b>, then press <b class="gd-ui">Send the invitation</b>. They get an email with your link to apply.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Copy my owner link</b>: your own link to the application, for a message or a post. Anyone who applies with it is credited to you.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Start an application</b>: you fill in the owner and the car for them, with <b class="gd-ui">Take a photo</b> (or <b class="gd-ui">Choose a photo</b>) of the ownership permit to fill in the car. It goes to an Admin as an application to approve. The terms and invoices are the Admin&#39;s. A corporation that leases its cars to CarmaCars: choose <b class="gd-ui">A corporation</b>, then Route <b class="gd-ui">Fleet supplier: leases the cars to CarmaCars</b>, and each car&#39;s tier (<b class="gd-ui">Regular</b> or <b class="gd-ui">Troubled</b>). A fleet supplier can also apply himself from <span class="gd-url">carmacars.ca/list-your-car</span>: your owner link works for it too.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The row of five figures follows your owners: <b class="gd-ui">Invited</b>, <b class="gd-ui">Applied</b>, <b class="gd-ui">Approved</b>, <b class="gd-ui">Car live</b> and <b class="gd-ui">First paid rental</b>. Below, each owner shows their stage and their cars.</div></li></ol></div><div class="gd-stepblock"><ol class="gd-ol" start="5"><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Someone who starts the application on the website and stops for 30 minutes comes to you: a task &quot;Unfinished owner application&quot; and their row on My sales (Lead). Call or text them; the follow-up emails go by themselves until they finish.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>An owner already on file, or invited first by another salesperson, cannot be invited again. Ask an Admin if you brought them in.</div></aside></section><section class="gd-task" id="sales-ask-for-your-commission-on-an-owner" data-gd-task><h2 class="gd-h2">Ask for your commission on an owner</h2><p class="gd-p">There is no set amount. For each owner you bring in, you ask for one, and an Admin decides.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the owner&#39;s row press <b class="gd-ui">Ask for a commission</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose <b class="gd-ui">A flat amount</b> and type it, or <b class="gd-ui">A percent</b>: type the percent, choose what it is of (the company&#39;s share of their cars&#39; rentals, or their cars&#39; rental revenue) and for how long (a number of months, or as long as the car is with us).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Add a note for the Admin if you like, then press <b class="gd-ui">Send to an Admin</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">While it waits you can press <b class="gd-ui">Change my request</b>. Once an Admin approves, changes or declines it, the row says so, with their note.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Approved as</th><th scope="col">When it is earned</th></tr></thead><tbody><tr><td>A flat amount</td><td>Once, at the owner&#39;s first paid rental: the first completed rental of any of their cars, paid in full</td></tr><tr><td>A percent</td><td>On each completed, paid rental of their cars that ends after the approval, from the month of the first one, for the months approved</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Nothing is earned before an Admin approves the request, and nothing on CarmaCars&#39; own cars, a partner&#39;s, a shareholder&#39;s or your own. Each commission then goes through the usual steps on My sales: pending approval, approved, paid.</div></aside></section><section class="gd-task" id="sales-buyer-leads" data-gd-task><h2 class="gd-h2">Buyer leads</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Buyer leads</b>: each request from the /buy pages, with the car, budget and timing.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Take it</b> to make it yours, then call them.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Update</b> to set the status. When you close a lead, say why.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Owner leads are not here. The owners you invite or add are on <b class="gd-ui">My sales</b>, <b class="gd-ui">Owners you bring in</b>, and you see only your own. Customer service works the full owner pipeline.</div></aside><p class="gd-p">An offer that has been expired for 7 days leaves Requests and offers and becomes a renter lead: you get the To do &quot;Expired offer: win the renter back&quot; (the lead goes to the Sales person with the fewest open leads) with the renter&#39;s contact, the car and the dates they wanted. Call or text them, then mark the lead contacted or closed.</p><p class="gd-p"><b class="gd-ui">Reopen offer</b> on an expired booking (or the <b class="gd-ui">Expired</b> filter of Requests) sends the offer again in one click, open 24 hours unless you set the hours; a pickup time that has passed asks for new dates first. &quot;Renter wants expired offer reopened&quot; To dos come from the renter&#39;s own button. The offer screens block <b class="gd-ui">Send</b> with <b class="gd-ui">Pickup time has passed: update it</b> until the pickup is moved.</p></section><section class="gd-task" id="sales-book-it-now-release-33" data-gd-task><h2 class="gd-h2">Book it now (release 33)</h2><p class="gd-p">When you send an offer, tick <b class="gd-ui">Book it now (no renter approval)</b> when the renter has already agreed. The offer goes out and an Admin approves it in one tap: the booking then waits for payment, the car is held, and the renter gets one link to sign and pay. You can also have them sign and pay with you: open the booking, <b class="gd-ui">Sign now on this device</b>, then take the card on this device. Already sent the offer? Ask the assistant: &quot;Book the offer of CC-10482 now, the customer agreed by phone&quot;. It shows a card; <b class="gd-ui">Confirm</b> sends the same request to an Admin, who approves in one tap.</p></section><section class="gd-task" id="sales-when-a-check-stops-the-pickup-or-the-return-release-33" data-gd-task><h2 class="gd-h2">When a check stops the pickup or the return (release 33)</h2><p class="gd-p">On the booking page, <b class="gd-ui">What stops the pickup now</b> (or the return) lists each check that stops it, in plain words. When the trip must go ahead anyway, press <b class="gd-ui">Ask an Admin to override the pickup</b> (or the return), give the actual time, the km and fuel if you know them, and why. An Admin gets an alert and approves in one tap; the pickup (or the return) is then recorded with the time you entered, and the booking&#39;s history says who asked and who approved. You can cancel your request while it waits. A trip that happened and was never recorded: <b class="gd-ui">Ask to record a past trip</b> with both times; once an Admin approves, the booking lands in Returned so the deposit can be settled.</p></section><section class="gd-task" id="sales-leads-and-claims" data-gd-task><h2 class="gd-h2">Leads and claims</h2><p class="gd-p">Open <b class="gd-ui">Leads</b>. Every lead is there: renter leads (forms, live chat, the phone number box, games, expired offers, requests not sent, missed calls, Live visitors), owner leads and partner leads, new and hot first. A new-lead alert on your phone opens that lead.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Next lead</b>, or <b class="gd-ui">Claim</b> on a card. The lead is yours for 15 minutes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Call</b>, <b class="gd-ui">Text</b> or <b class="gd-ui">Email</b>: your phone or mail app opens and the contact is logged. Each contact (or <b class="gd-ui">Note</b>) adds 15 minutes, up to 60 minutes from your claim.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Outcome</b>: Contacted, Call booked, Applied, Won or Lost (say why). Or <b class="gd-ui">Mark handled</b> when there is nothing more to do.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Can&#39;t finish? Press <b class="gd-ui">Unclaim</b> so someone else can take it. A claim that runs out goes back to the pool by itself.</div></li></ol></div><p class="gd-p">You hold at most 25 leads at once. Your numbers are on To do under <b class="gd-ui">My leads</b>: leads claimed, won, close rate (won out of claimed), contacted, time to first contact and claims that ran out, today, this week and this month. Owner leads are also under <b class="gd-ui">Owners</b> &gt; <b class="gd-ui">Leads</b>.</p></section><section class="gd-task" id="sales-the-person-behind-the-lead-release-40" data-gd-task><h2 class="gd-h2">The person behind the lead (release 40)</h2><p class="gd-p">Press <b class="gd-ui">The person</b> on a lead card, or open the lead, to see everything we know about them in one place: their name and the name they go by, phone and email, account and whether the licence is verified (yes or no, never the number), every booking with the car, dates, status, total and anything owed, the deposit, open requests and offers sent, their earlier leads, messages, calls and texts, notes, reviews, incidents, and who has handled them. <b class="gd-ui">Signals</b> lists everything they did with us, newest first: calls and texts, WhatsApp, chat, emails, visits, cars and offers looked at, bookings and reviews. The intent score counts all of it.</p><p class="gd-p">When the renter is outside your window, you see their contact and account until the lead is yours: claim it (or an Admin assigns it to you) and the rest opens, logged as a record you opened for a reason. An Admin can assign leads to you in bulk: they show <b class="gd-ui">Assigned to you by an Admin</b>, do not run out, and do not count against your limit of open leads.</p></section><section class="gd-task" id="sales-call-minutes-release-35" data-gd-task><h2 class="gd-h2">Call minutes (release 35)</h2><p class="gd-p">Your home shows <b class="gd-ui">My call minutes</b>: today, this week and this month, for connected calls made with the site&#39;s <b class="gd-ui">Call</b> button. Customer numbers are hidden for Sales; call and text with the buttons on the page.</p></section><section class="gd-task" id="sales-get-a-renter-ready-for-the-pickup-release-35" data-gd-task><h2 class="gd-h2">Get a renter ready for the pickup (release 35)</h2><p class="gd-p">Your work does not stop at the offer. Until the car is handed over you can do everything that gets the renter good to go:</p><ul class="gd-ul"><li><b class="gd-ui">Payment</b>: send a pay link or a deposit link on Money (text or email), or take the card on this device, also on a confirmed booking.</li><li><b class="gd-ui">The offer</b>: edit it, send it again with a later expiry, withdraw it or record that the renter approved by phone, also while it waits for payment.</li><li><b class="gd-ui">ID and coverage</b>: approve or reject the licence, the selfie and the proof of coverage, with the reason the renter sees.</li><li><b class="gd-ui">Drivers and agreement</b>: send each additional driver their signing link, or the agreement again.</li><li><b class="gd-ui">Name change asked for</b>: when a verified renter asks for a name or date of birth correction, it shows on the booking; check it against the licence, then <b class="gd-ui">Approve</b> or <b class="gd-ui">Decline</b>.</li></ul><p class="gd-p">The booking page shows <b class="gd-ui">Ready for the rental</b>: one line for each thing the pickup needs (offer accepted, paid, licence and selfie, coverage, deposit, drivers, agreement, add-ons in the car), green when done, with what to press when not. Refunds, cancellations, deposit releases and removing a paid add-on stay with customer service, Finance and Admins.</p></section><section class="gd-task" id="sales-the-prepare-checklist-release-35" data-gd-task><h2 class="gd-h2">The Prepare checklist (release 35)</h2><p class="gd-p">On a booking with add-ons, <b class="gd-ui">Prepare for the pickup</b> shows each add-on with its quantity, ticked or not by field staff, who ticked it and when, and the pickup or delivery job with its field person. It is on the booking and on the car page, for Sales, customer service, Fleet and Finance.</p></section><section class="gd-task" id="sales-rebooking-intent-and-offers-release-35" data-gd-task><h2 class="gd-h2">Rebooking, intent and offers (release 35)</h2><ul class="gd-ul"><li>A returning renter&#39;s new request comes straight to you when you had their last booking, with the usual claim time.</li><li>Each lead shows its intent (hot, warm or cold) and what the person said they want, read from calls with their transcripts, texts, emails, chat and visits. Call hot leads first.</li><li>Offers are three steps: car and dates, price, review and send. Every version is kept; you can load an old one as a new offer.</li><li>Prices stay between the owner&#39;s daily minimum and maximum; only an Admin allows one outside them.</li><li>Repeat renters who are verified can book instantly; their booking is marked Instant (repeat renter).</li><li>Rewards: tell renters they earn points for a photo with their review and every rental after the first.</li></ul></section><section class="gd-task" id="sales-calls-first-texts-after-release-37" data-gd-task><h2 class="gd-h2">Calls first, texts after (release 37)</h2><p class="gd-p">Your main priority is always to be on the phone with people.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Answer a ringing call before anything else, and return a missed call at once.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Call before you text.</b> On a lead, a renter or a booking, <b class="gd-ui">Call</b> is the first button and <b class="gd-ui">Text</b> the second.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A text is a follow-up: after a call attempt (no answer, a voicemail left), or when the person asked for a text.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On your To do and on <b class="gd-ui">Unanswered</b>, missed calls and call-backs are listed above unanswered texts.</div></li></ol></div></section><section class="gd-task" id="sales-a-lead-customer-service-is-handling-release-37" data-gd-task><h2 class="gd-h2">A lead customer service is handling (release 37)</h2><p class="gd-p">When customer service or Fleet are on a call with a lead, the lead and the lists say <b class="gd-ui">Being handled by</b> their first name, their function and the time. Leave it alone: you cannot claim it, call, text or email it, or set an outcome, and <b class="gd-ui">Next lead</b> skips it. When their time ends, the lead returns to you if you had a claim on it or brought it, else to the open list. The booking credit rules do not change.</p></section>');
-- GUIDES 2411 END
