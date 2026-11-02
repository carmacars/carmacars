-- 0462: one staff-alert system: a rule table, one emitter, one feed (docs/changes/2026-11-07-lead-alerts.md).
-- The owner: "every important email or text sent to other people should notify us", the booking from request to closed,
-- the field work, money, reviews, hiring, a morning brief and an evening wrap, and "an urgent alert nobody opened".
--
-- 1. staff_alert_rules: one row per kind of alert (rule): who gets it (admin, the assigned person, a function on duty,
--    a function on duty only when nobody is assigned), its tier and its push topic, on by default.
--      urgent  push at once, at any hour (sent as urgent)
--      normal  push, held until the staff quiet hours end (21:00 to 8:00, the text quiet hours)
--      digest  an in-app line and an item in the daily staff digest; never a push
--    wired = the database makes this alert today; not wired rows are listed so the Admin sees what is planned.
-- 2. app.staff_alert(rule, entity, id, disc, title, body, extra): the only emitter. Reads the rule (off or missing:
--    nothing), makes the event staff_alert_<tier> once per rule, record and disc. Recipients come from
--    app.staff_alert_users; never a test account. All three notices are in the app (the feed is the bell and the
--    notifications list) and, for urgent and normal, on the phone by the rule's topic. No email, so the daily email limit
--    is untouched.
-- 3. Hooks (all failure-proof: an alert never stops the work): a mirror of the important notices that go out to
--    renters, owners and investors (notification_outbox), the booking from confirmed to closed and no-show, a payment
--    over the threshold, a refund paid, a review, a toll or ticket, field jobs, a new job application, usage over its
--    allowance; a job every 5 minutes for late field jobs, offers expiring within the hour, escalation (an urgent alert
--    nobody opened within alert_escalate_minutes goes to the Admins), the morning brief at 8:00 and the evening wrap and
--    cash summary at 21:00 (Toronto).
-- 4. Admins get every topic by default (they asked to be alerted for everything).
-- SCHEMA_MARKER 0463 (0461 carries the guide chapters). No applied migration is edited.
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
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0462: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. settings and the rule table
alter table program_settings
  add column if not exists alert_money_threshold_cents bigint not null default 50000 check (alert_money_threshold_cents >= 0),
  add column if not exists alert_escalate_enabled boolean not null default true,
  add column if not exists alert_escalate_minutes integer not null default 15 check (alert_escalate_minutes between 1 and 240),
  add column if not exists alert_brief_enabled boolean not null default true;
comment on column program_settings.alert_money_threshold_cents is 'Staff alerts (0462): a payment received at or over this many cents alerts the Admins (500 dollars).';
comment on column program_settings.alert_escalate_enabled is 'Staff alerts (0462): an urgent alert nobody opened within alert_escalate_minutes is sent again to the Admins.';
comment on column program_settings.alert_escalate_minutes is 'Staff alerts (0462): minutes before an unopened urgent alert escalates (15).';
comment on column program_settings.alert_brief_enabled is 'Staff alerts (0462): the morning brief at 8:00 and the evening wrap and cash summary at 21:00 (Toronto).';

create table staff_alert_rules (
  rule     text primary key check (rule ~ '^[a-z][a-z0-9_:]*$'),
  label    text not null,
  grp      text not null,
  who      text[] not null default '{admin}',
  tier     text not null default 'normal' check (tier in ('urgent', 'normal', 'digest')),
  topic    text not null default 'alerts' check (topic in ('requests', 'bookings', 'payments', 'handovers', 'messages', 'alerts', 'documents', 'leads', 'visitors')),
  enabled  boolean not null default true,
  wired    boolean not null default false,
  fixed    boolean not null default false,
  hint     text,
  sort     integer not null default 100,
  updated_at timestamptz not null default now()
);
comment on table staff_alert_rules is 'Staff alerts (0462): one row per kind of alert. who: admin, assigned, on_duty:<function>, unassigned_on_duty:<function>. tier: urgent (push at once), normal (push after the quiet hours), digest (in the app and the daily digest only). fixed rows are the lead alerts of 0460, switched in Program settings.';
alter table staff_alert_rules enable row level security;
create policy admin_all on staff_alert_rules for all to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger staff_alert_rules_updated before update on staff_alert_rules for each row execute function app.set_updated_at();
create trigger audit_staff_alert_rules after insert or update or delete on staff_alert_rules for each row execute function app.audit_row();
revoke all on staff_alert_rules from anon, authenticated;
grant select, update on staff_alert_rules to authenticated;
grant all on staff_alert_rules to service_role;

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  -- the lead alerts of 0460 (switched in Program settings)
  ('staff_lead_new', 'New renter lead', 'Leads', '{admin,assigned,unassigned_on_duty:cs,unassigned_on_duty:sales}', 'urgent', 'leads', true, true, 'Program settings > Text alerts', 10),
  ('staff_request_unfinished', 'Request typed and not sent', 'Leads', '{admin,assigned,unassigned_on_duty:cs,unassigned_on_duty:sales}', 'urgent', 'leads', true, true, 'Program settings > Text alerts', 11),
  ('staff_owner_lead_new', 'New owner lead', 'Leads', '{admin,assigned}', 'urgent', 'leads', true, true, 'Program settings > Text alerts', 12),
  ('staff_hot_visitor', 'Visitor turned Hot', 'Leads', '{admin,on_duty:cs,on_duty:sales}', 'urgent', 'visitors', true, true, 'Program settings > Text alerts', 13),
  -- a mirror of what goes out to other people
  ('sent:renter_late_return_first', 'Sent: late return notice (T13)', 'Sent to others', '{admin}', 'urgent', 'alerts', true, false, 'The renter was told their return is late.', 20),
  ('sent:renter_late_return_final', 'Sent: final late return notice (T14)', 'Sent to others', '{admin}', 'urgent', 'alerts', true, false, null, 21),
  ('sent:renter_return_due', 'Sent: return time notice', 'Sent to others', '{admin}', 'urgent', 'alerts', true, false, null, 22),
  ('sent:renter_balance_overdue', 'Sent: balance overdue', 'Sent to others', '{admin}', 'normal', 'payments', true, false, null, 23),
  ('sent:renter_payment_failed', 'Sent: payment failed', 'Sent to others', '{admin}', 'normal', 'payments', true, false, null, 24),
  ('sent:renter_recovery_pay', 'Sent: payment link', 'Sent to others', '{admin}', 'normal', 'payments', true, false, null, 25),
  ('sent:owner_debit_returned', 'Sent: owner debit failed or refused', 'Sent to others', '{admin}', 'urgent', 'alerts', true, false, null, 26),
  ('sent:owner_statement_ready', 'Sent: owner statement', 'Sent to others', '{admin}', 'digest', 'payments', true, false, null, 27),
  ('sent:owner_payout_sent', 'Sent: owner payout', 'Sent to others', '{admin}', 'digest', 'payments', true, false, null, 28),
  ('sent:investor_return_paid', 'Sent: investor payout', 'Sent to others', '{admin}', 'digest', 'payments', true, false, null, 29),
  ('sent:renter_offer_ready', 'Sent: offer to renter', 'Sent to others', '{admin}', 'digest', 'requests', true, false, null, 30),
  ('sent:renter_agreement_ready', 'Sent: agreement to sign (renter)', 'Sent to others', '{admin}', 'digest', 'documents', true, false, null, 31),
  ('sent:owner_agreement_ready', 'Sent: agreement to sign (owner)', 'Sent to others', '{admin}', 'digest', 'documents', true, false, null, 32),
  -- money
  ('payment_received', 'Payment received over the threshold', 'Money', '{admin}', 'normal', 'payments', true, false, 'Program setting alert_money_threshold_cents (500 dollars).', 40),
  ('refund_issued', 'Refund issued', 'Money', '{admin}', 'normal', 'payments', true, false, null, 41),
  ('cash_summary', 'Daily cash summary, 9 pm', 'Money', '{admin}', 'digest', 'payments', true, false, null, 42),
  ('deposit_hold_failed', 'Deposit hold failed', 'Money', '{admin}', 'urgent', 'alerts', false, false, null, 43),
  ('card_declined_pickup', 'Card declined at pickup', 'Money', '{admin,on_duty:fleet}', 'urgent', 'alerts', false, false, null, 44),
  ('investor_money_in', 'Investor money received', 'Money', '{admin}', 'normal', 'payments', false, false, null, 45),
  -- the booking, step by step
  ('booking_confirmed', 'Booking paid and confirmed', 'Bookings', '{admin}', 'normal', 'bookings', true, false, null, 50),
  ('offer_sent', 'Offer sent to the renter', 'Bookings', '{admin}', 'digest', 'requests', true, false, null, 51),
  ('offer_expiring', 'Offer expires within the hour', 'Bookings', '{admin,on_duty:sales}', 'normal', 'requests', true, false, null, 52),
  ('booking_out', 'Car going out (pickup recorded)', 'Bookings', '{admin,on_duty:fleet}', 'normal', 'bookings', true, false, null, 53),
  ('booking_back', 'Car back (return recorded)', 'Bookings', '{admin,on_duty:fleet}', 'normal', 'bookings', true, false, null, 54),
  ('booking_closed', 'Booking closed', 'Bookings', '{admin}', 'digest', 'bookings', true, false, null, 55),
  ('booking_no_show', 'No-show', 'Bookings', '{admin,on_duty:fleet}', 'urgent', 'alerts', true, false, null, 56),
  ('offer_viewed', 'Offer viewed by the renter', 'Bookings', '{admin}', 'digest', 'requests', false, false, null, 57),
  ('offer_accepted', 'Offer accepted', 'Bookings', '{admin}', 'normal', 'requests', false, false, null, 58),
  ('extension_paid', 'Extension asked or paid', 'Bookings', '{admin}', 'normal', 'bookings', false, false, null, 59),
  ('date_change', 'Date change asked or approved', 'Bookings', '{admin}', 'normal', 'bookings', false, false, null, 60),
  ('deposit_released', 'Deposit released', 'Bookings', '{admin}', 'digest', 'payments', false, false, null, 61),
  ('insurer_claim_missing', 'Insurer booking without claim number at pickup', 'Bookings', '{admin,on_duty:cs}', 'normal', 'alerts', false, false, null, 62),
  -- field work
  ('job_assigned', 'Field job assigned', 'Field work', '{admin,assigned}', 'normal', 'handovers', true, false, null, 70),
  ('job_started', 'Field job started', 'Field work', '{admin}', 'normal', 'handovers', true, false, null, 71),
  ('job_done', 'Field job finished', 'Field work', '{admin}', 'digest', 'handovers', true, false, null, 72),
  ('job_late', 'Field job running late', 'Field work', '{admin,assigned}', 'urgent', 'alerts', true, false, 'Scheduled 15 minutes ago and not started.', 73),
  ('handover_checklist_incomplete', 'Handover checklist incomplete', 'Field work', '{admin}', 'normal', 'handovers', false, false, null, 74),
  ('return_fuel_km', 'Fuel or km off at return', 'Field work', '{admin}', 'normal', 'handovers', false, false, null, 75),
  -- customers
  ('review_low', 'Review of 3 stars or less', 'Customers', '{admin,on_duty:cs}', 'urgent', 'messages', true, false, null, 80),
  ('review_new', 'New review', 'Customers', '{admin}', 'normal', 'messages', true, false, null, 81),
  ('review_five', '5-star review', 'Customers', '{admin}', 'normal', 'messages', true, false, null, 82),
  ('complaint_keyword', 'Complaint words in chat or email', 'Customers', '{admin,on_duty:cs}', 'normal', 'messages', false, false, null, 83),
  ('account_delete_request', 'Asked to delete their account', 'Customers', '{admin}', 'normal', 'messages', false, false, null, 84),
  ('opt_out', 'Opt-out or unsubscribe', 'Customers', '{admin}', 'digest', 'messages', false, false, null, 85),
  -- documents, fleet, owners
  ('toll_received', 'Toll or ticket received', 'Fleet and cars', '{admin}', 'digest', 'alerts', true, false, null, 90),
  ('licence_review', 'Licence uploaded, needs review', 'Documents', '{admin,on_duty:cs}', 'normal', 'documents', false, false, null, 91),
  ('agreement_signed', 'Agreement signed', 'Documents', '{admin}', 'digest', 'documents', false, false, null, 92),
  ('agreement_unsigned_pickup', 'Agreement unsigned 2 hours before pickup', 'Documents', '{admin,on_duty:cs}', 'urgent', 'alerts', false, false, null, 93),
  ('insurance_missing', 'Insurance proof missing 24 hours before pickup', 'Documents', '{admin,on_duty:cs}', 'normal', 'documents', false, false, null, 94),
  ('tracker_offline', 'Tracker offline over 2 hours on rent', 'Fleet and cars', '{admin,on_duty:fleet}', 'urgent', 'alerts', false, false, 'Needs the tracker feed (r27-tracker).', 95),
  ('geofence_exit', 'Geofence exit, speeding, after-hours movement', 'Fleet and cars', '{admin,on_duty:fleet}', 'urgent', 'alerts', false, false, 'Needs the tracker feed (r27-tracker).', 96),
  ('maintenance_due', 'Car due for service or inspection within 7 days', 'Fleet and cars', '{admin}', 'digest', 'alerts', false, false, null, 97),
  ('car_unpublished', 'Car unpublished or blocked unexpectedly', 'Fleet and cars', '{admin}', 'normal', 'alerts', false, false, null, 98),
  ('owner_notice', 'Owner gave notice or asked to leave', 'Owners and investors', '{admin}', 'urgent', 'alerts', false, false, null, 100),
  ('owner_banking_changed', 'Owner changed banking', 'Owners and investors', '{admin}', 'urgent', 'alerts', false, false, null, 101),
  ('investor_invested', 'Investor signed or invested', 'Owners and investors', '{admin}', 'normal', 'payments', false, false, null, 102),
  -- staff and system
  ('usage_80', 'Usage over 80% of an allowance', 'System', '{admin}', 'normal', 'alerts', true, false, 'No email; this is the alert.', 110),
  ('application_new', 'New job application', 'Hiring', '{admin}', 'normal', 'requests', true, false, null, 111),
  ('admin_new_device', 'Admin sign-in from a new device or country', 'System', '{admin}', 'urgent', 'alerts', false, false, null, 112),
  ('failed_sign_ins', 'Burst of failed sign-ins', 'System', '{admin}', 'urgent', 'alerts', false, false, null, 113),
  ('deploy_result', 'Deploy finished or failed', 'System', '{admin}', 'normal', 'alerts', false, false, null, 114),
  ('data_health', 'Data health found new problems', 'System', '{admin}', 'digest', 'alerts', false, false, 'Reuse staff_data_health when r27-health is merged.', 115),
  ('interview_finished', 'AI interview finished', 'Hiring', '{admin}', 'normal', 'requests', false, false, 'Needs the interview tables (r27-interviews).', 116),
  ('academy_progress', 'Academy lesson, quiz or certification', 'Staff', '{admin}', 'digest', 'alerts', false, false, null, 120),
  ('staff_idle', 'Staff has not touched their queue in 2 hours', 'Staff', '{admin}', 'normal', 'alerts', false, false, null, 121),
  ('win_first_booking', 'First booking of a newly listed car', 'Wins', '{admin}', 'normal', 'bookings', false, false, null, 130),
  ('win_record_day', 'Record day or week of revenue', 'Wins', '{admin}', 'normal', 'payments', false, false, null, 131),
  ('win_first_payout', 'Owner car earned its first payout', 'Wins', '{admin}', 'digest', 'payments', false, false, null, 132),
  ('win_month_totals', 'Monthly totals on the 1st', 'Wins', '{admin}', 'digest', 'payments', false, false, null, 133),
  -- scheduled
  ('morning_brief_admin', 'Morning brief (Admin), 8 am', 'Briefs', '{admin}', 'normal', 'alerts', true, false, null, 140),
  ('morning_brief_staff', 'Morning brief (your own), 8 am', 'Briefs', '{assigned}', 'normal', 'alerts', true, false, null, 141),
  ('evening_wrap', 'Evening wrap (Admin), 9 pm', 'Briefs', '{admin}', 'urgent', 'payments', true, false, 'Sent as urgent so the staff quiet hours (from 9 pm) do not hold it.', 142),
  ('escalation', 'Urgent alert nobody opened', 'Briefs', '{admin}', 'urgent', 'alerts', true, false, 'alert_escalate_minutes in Program settings.', 143);

-- ================================================================ 2. the three notices and the push
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, subject, preheader, has_email, priority, emitted_by, link_path,
                                    timing, trigger_text, variables, push_topic)
select 'staff_alert_' || t.tier, 'staff_admin', '{}'::text[], 'transactional', t.tier = 'digest', case when t.tier = 'digest' then 'next' end,
       '{{alert_title}}', '{{alert_body}}', false, 3, 'app.staff_alert (0462)', null, t.timing, t.trig,
       '[{"name":"alert_title","type":"string"},{"name":"alert_body","type":"string"}]'::jsonb, null
  from (values ('urgent', 'When it happens', 'A staff alert of the urgent tier (Settings > Staff alerts). Phone alert at once, at any hour; the rule says who. Not for test accounts.'),
               ('normal', 'When it happens', 'A staff alert of the normal tier. Phone alert, held until the staff quiet hours (9 pm to 8 am) end; the rule says who.'),
               ('digest', 'When it happens', 'A staff alert of the digest tier: a line in the app and an item in the daily staff digest; never a phone alert.')) t(tier, timing, trig)
on conflict (code) do nothing;
select app.notification_catalogue_refresh();

-- the phone: the topic comes from the rule (in the event), a digest never pushes, a normal one waits for the quiet hours
select pg_temp.patch_fn('app.push_from_notice()'::regprocedure,
  'select c.push_topic into v_topic from notification_catalogue c where c.code = new.code;',
  'select c.push_topic into v_topic from notification_catalogue c where c.code = new.code;
  if new.code in (''staff_alert_urgent'', ''staff_alert_normal'') then
    select e.payload ->> ''topic'' into v_topic from app_events e where e.id = new.event_id;
  end if;');
select pg_temp.patch_fn('app.push_from_notice()'::regprocedure,
  'v_urgent := v_topic in (''alerts'', ''leads'');',
  'v_urgent := v_topic in (''alerts'', ''leads'') or new.code = ''staff_alert_urgent'';');
select pg_temp.patch_fn('app.push_from_notice()'::regprocedure,
  'if not v_urgent and v_role in (''renter'', ''owner'', ''investor'') then',
  'if not v_urgent and (v_role in (''renter'', ''owner'', ''investor'') or new.code = ''staff_alert_normal'') then');

-- Admins want everything: every topic by default (and the ones they had chosen before these topics get the rest)
create or replace function app.push_default_topics(p_role text) returns text[]
language sql immutable as $$
  select case p_role
    when 'admin' then array['requests', 'bookings', 'payments', 'handovers', 'messages', 'alerts', 'documents', 'leads', 'visitors']
    when 'staff' then array['requests', 'bookings', 'messages', 'alerts']
    when 'field' then array['handovers', 'payments']
    when 'owner' then array['requests', 'bookings', 'payments', 'alerts', 'documents']
    when 'investor' then array['payments', 'messages', 'documents']
    else array['requests', 'bookings', 'payments', 'handovers', 'messages', 'alerts', 'documents'] end::text[]
$$;
update push_preferences pp
   set topics = array(select distinct t from unnest(pp.topics || array['bookings', 'handovers', 'documents']::text[]) t order by 1), updated_at = now()
 where app.push_role(pp.user_id) = 'admin';

-- ================================================================ 3. who
create or replace function app.staff_alert_users(p_rule text, p jsonb) returns table (user_id uuid, audience text)
language plpgsql stable security definer set search_path = public, app as $$
declare
  r staff_alert_rules;
  v_assigned uuid := nullif(p ->> 'assigned_to', '')::uuid;
  v_shift integer := (app.settings()).chat_shift_minutes;
begin
  select * into r from staff_alert_rules x where x.rule = p_rule;
  if r.rule is null then return; end if;
  return query
    select distinct on (c.uid) c.uid, c.aud
      from (
        select u.id uid, 'staff_admin'::text aud, 0 ord
          from users u where 'admin' = any (r.who) and u.status = 'active' and exists (select 1 from user_roles x where x.user_id = u.id and x.role::text = 'admin')
        union all
        select u.id, case when sp.staff_type = 'field' then 'staff_field' else 'staff_va_' || sp.va_function::text end, 1
          from users u join staff_profiles sp on sp.user_id = u.id and sp.is_active
         where 'assigned' = any (r.who) and u.id = v_assigned and u.status = 'active'
        union all
        select u.id, 'staff_va_' || sp.va_function::text, 2
          from users u join staff_profiles sp on sp.user_id = u.id and sp.staff_type = 'va' and sp.is_active
          join chat_staff_prefs cp on cp.user_id = u.id and cp.last_seen_at > now() - make_interval(mins => v_shift)
         where u.status = 'active'
           and exists (select 1 from unnest(r.who) w
                        where (w like 'on_duty:%' or (w like 'unassigned_on_duty:%' and v_assigned is null))
                          and split_part(w, ':', 2) in (sp.va_function::text, (select x::text from unnest(sp.cover_functions) x where x::text = split_part(w, ':', 2))))
      ) c
     where not app.staff_is_test(c.uid)
     order by c.uid, c.ord;
end $$;

alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_pre0462;
create function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_c.code in ('staff_alert_urgent', 'staff_alert_normal', 'staff_alert_digest') then
    return query select x.audience, u.id, u.email, u.full_name, null::uuid, null::uuid, p_c.code <> 'staff_alert_digest'
                   from app.staff_alert_users(p_event.payload ->> 'rule', p_event.payload) x join users u on u.id = x.user_id;
    return;
  end if;
  return query select * from app.notification_recipients_pre0462(p_event, p_c);
end $$;
select pg_temp.copy_grants('app.notification_recipients(app_events, notification_catalogue)'::regprocedure,
                           'app.notification_recipients_pre0462(app_events, notification_catalogue)'::regprocedure);

alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0462;
create function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := coalesce(app.ntf_payload_pre0462(p_code, p_event, p_to), '{}'::jsonb);
  v_path text;
begin
  if p_code in ('staff_alert_urgent', 'staff_alert_normal', 'staff_alert_digest') then
    v_path := case when p_to ->> 'audience' = 'staff_admin' then p_event.payload ->> 'path_admin' else p_event.payload ->> 'path_staff' end;
    x := x || jsonb_build_object('alert_title', coalesce(p_event.payload ->> 'alert_title', ''), 'alert_body', coalesce(p_event.payload ->> 'alert_body', ''),
                                 '_url', (app.settings()).notify_base_url || coalesce(v_path, case when p_to ->> 'audience' = 'staff_admin' then '/admin' else '/staff' end));
  end if;
  return x;
end $$;
select pg_temp.copy_grants('app.notification_payload(text, app_events, jsonb)'::regprocedure, 'app.ntf_payload_pre0462(text, app_events, jsonb)'::regprocedure);

-- ================================================================ 4. the one emitter
create or replace function app.staff_alert(p_rule text, p_entity text, p_id uuid, p_disc text, p_title text, p_body text, p_extra jsonb default '{}'::jsonb)
returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  r staff_alert_rules;
begin
  select * into r from staff_alert_rules where rule = p_rule;
  if r.rule is null or not r.enabled then return null; end if;
  return app.ntf_emit('staff_alert_' || r.tier, p_entity, p_id, p_rule || ':' || coalesce(p_disc, 'x'),
    jsonb_build_object('rule', p_rule, 'topic', r.topic, 'alert_title', left(p_title, 140), 'alert_body', left(coalesce(p_body, ''), 240)) || coalesce(p_extra, '{}'::jsonb));
end $$;

-- the lead alerts of 0460 honour their rule's switch too
create or replace function app.lead_alert_emit(p_code text, p_entity text, p_id uuid, p_disc text, p_title text, p_body text, p_extra jsonb default '{}'::jsonb)
returns bigint
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_on boolean;
  v_n integer;
begin
  v_on := case p_code when 'staff_lead_new' then s.notify_lead_new when 'staff_request_unfinished' then s.notify_request_unfinished
                      when 'staff_owner_lead_new' then s.notify_owner_lead_new when 'staff_hot_visitor' then s.notify_hot_visitor end;
  if not coalesce(v_on, true) or not coalesce((select x.enabled from staff_alert_rules x where x.rule = p_code), true) then return null; end if;
  if p_code in ('staff_lead_new', 'staff_request_unfinished') then
    select count(*) into v_n from app_events e
     where e.code in ('staff_lead_new', 'staff_request_unfinished') and e.created_at > now() - make_interval(mins => s.notify_lead_burst_minutes)
       and coalesce(e.payload ->> 'burst', '') <> 'true';
    if v_n >= s.notify_lead_burst_count then
      return app.ntf_emit('staff_lead_new', 'lead_alert', null, 'burst:' || floor(extract(epoch from now()) / (s.notify_lead_burst_minutes * 60))::bigint,
        jsonb_build_object('burst', 'true', 'alert_title', format('%s new leads in %s minutes', v_n + 1, s.notify_lead_burst_minutes),
                           'alert_body', 'Open Leads to see them all and who is on each.'));
    end if;
  end if;
  return app.ntf_emit(p_code, p_entity, p_id, p_disc,
    jsonb_build_object('alert_title', left(p_title, 140), 'alert_body', left(coalesce(p_body, ''), 240)) || coalesce(p_extra, '{}'::jsonb));
end $$;

-- ================================================================ 5. hooks
-- one booking in a line: number, car, renter
create or replace function app.sa_booking_line(b bookings) returns text
language sql stable security definer set search_path = public, app as $$
  select b.booking_number || ', ' || coalesce(app.vehicle_name(b.vehicle_id), 'car') || ', ' || coalesce((select r.legal_name from renters r where r.id = b.renter_id), 'renter')
$$;
create or replace function app.sa_booking_paths(b bookings) returns jsonb
language sql immutable as $$ select jsonb_build_object('path_admin', '/admin/bookings/' || b.booking_number, 'path_staff', '/staff/bookings/' || b.booking_number, 'booking_id', b.id) $$;

create or replace function app.sa_booking_alert(p_b bookings) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_rule text;
  v_title text;
  v_when timestamptz;
begin
  if coalesce(p_b.is_placeholder, false) or p_b.booking_type = 'owner' then return; end if;
  if app.email_is_test((select r.email from renters r where r.id = p_b.renter_id)) then return; end if;
  select x.r, x.t, x.w into v_rule, v_title, v_when from (values
      ('confirmed', 'booking_confirmed', 'Booking confirmed', p_b.pickup_at),
      ('on_rent', 'booking_out', 'Car going out', p_b.pickup_at),
      ('returned', 'booking_back', 'Car back', p_b.return_at),
      ('closed', 'booking_closed', 'Booking closed', p_b.return_at),
      ('no_show', 'booking_no_show', 'No-show', p_b.pickup_at)) x(s, r, t, w) where x.s = p_b.status::text;
  if v_rule is null then return; end if;
  perform app.staff_alert(v_rule, 'booking', p_b.id, p_b.status::text, v_title || ': ' || app.sa_booking_line(p_b),
    case v_rule when 'booking_back' then 'Return time ' else 'Pickup time ' end || app.fmt_at(v_when), app.sa_booking_paths(p_b));
end $$;

create or replace function app.sa_booking_status() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  begin
    perform app.sa_booking_alert(new);
  exception when others then
    raise warning 'booking alert not made for %: %', new.id, sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists bookings_z_staff_alert on bookings;
create trigger bookings_z_staff_alert after update of status on bookings for each row when (old.status is distinct from new.status) execute function app.sa_booking_status();

create or replace function app.sa_offer_sent() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare b bookings;
begin
  begin
    if new.kind <> 'offer_sent' then return null; end if;
    select * into b from bookings where id = new.booking_id;
    if b.id is null or coalesce(b.is_placeholder, false) or app.email_is_test((select r.email from renters r where r.id = b.renter_id)) then return null; end if;
    perform app.staff_alert('offer_sent', 'booking', b.id, 'v' || coalesce(new.offer_version, 0), 'Offer sent: ' || app.sa_booking_line(b), 'Pickup ' || app.fmt_at(b.pickup_at), app.sa_booking_paths(b));
  exception when others then
    raise warning 'offer alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists booking_events_z_staff_alert on booking_events;
create trigger booking_events_z_staff_alert after insert on booking_events for each row when (new.kind = 'offer_sent') execute function app.sa_offer_sent();

-- the mirror of what goes out to renters, owners and investors
create or replace function app.sa_outbox_mirror() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_title text;
begin
  begin
    if not exists (select 1 from staff_alert_rules where rule = 'sent:' || new.code) or app.email_is_test(new.to_address) then return null; end if;
    select * into b from bookings where id = new.booking_id;
    select c.subject into v_title from notification_catalogue c where c.code = new.code;
    perform app.staff_alert('sent:' || new.code, 'outbox', new.id, new.code,
      'Sent to ' || coalesce(nullif(new.to_name, ''), new.audience) || ': ' || coalesce(app.render_text(v_title, new.payload), new.code),
      coalesce('Booking ' || b.booking_number, 'No booking') || ' (' || new.audience || ')',
      case when b.id is not null then app.sa_booking_paths(b) else '{}'::jsonb end);
  exception when others then
    raise warning 'mirror alert not made for %: %', new.id, sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists notification_outbox_z_staff_alert on notification_outbox;
create trigger notification_outbox_z_staff_alert after insert on notification_outbox for each row
  when (new.audience in ('renter', 'owner', 'investor')) execute function app.sa_outbox_mirror();

-- money
create or replace function app.sa_payment() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare b bookings;
begin
  begin
    if new.status <> 'succeeded' or new.kind not in ('charge', 'capture') or new.amount_cents < (app.settings()).alert_money_threshold_cents then return null; end if;
    if tg_op = 'UPDATE' and old.status = 'succeeded' then return null; end if;
    select * into b from bookings where id = new.booking_id;
    if b.id is not null and app.email_is_test((select r.email from renters r where r.id = b.renter_id)) then return null; end if;
    perform app.staff_alert('payment_received', 'payment', new.id, 'ok', 'Payment received: ' || app.fmt_money(new.amount_cents),
      coalesce(app.sa_booking_line(b), 'No booking'), case when b.id is not null then app.sa_booking_paths(b) else '{}'::jsonb end);
  exception when others then
    raise warning 'payment alert not made for %: %', new.id, sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists payments_z_staff_alert on payments;
create trigger payments_z_staff_alert after insert or update of status on payments for each row when (new.status = 'succeeded') execute function app.sa_payment();

create or replace function app.sa_refund() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare b bookings;
begin
  begin
    if tg_op = 'UPDATE' and old.status = 'paid' then return null; end if;
    select * into b from bookings where id = new.booking_id;
    perform app.staff_alert('refund_issued', 'refund', new.id, 'paid', 'Refund issued: ' || app.fmt_money(new.amount_cents),
      coalesce(app.sa_booking_line(b), 'No booking'), case when b.id is not null then app.sa_booking_paths(b) else '{}'::jsonb end);
  exception when others then
    raise warning 'refund alert not made for %: %', new.id, sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists refunds_z_staff_alert on refunds;
create trigger refunds_z_staff_alert after insert or update of status on refunds for each row when (new.status = 'paid') execute function app.sa_refund();

-- reviews, tolls, applications, usage, field jobs
create or replace function app.sa_review() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare b bookings;
begin
  begin
    select * into b from bookings where id = new.booking_id;
    perform app.staff_alert(case when new.rating <= 3 then 'review_low' when new.rating = 5 then 'review_five' else 'review_new' end, 'review', new.id, 'new',
      'New review: ' || new.rating || ' stars' || coalesce(', ' || app.vehicle_name(new.vehicle_id), ''), left(coalesce(nullif(new.title, ''), new.body, ''), 200),
      jsonb_build_object('path_admin', '/admin/reviews', 'path_staff', '/staff/reviews'));
  exception when others then
    raise warning 'review alert not made for %: %', new.id, sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists reviews_z_staff_alert on reviews;
create trigger reviews_z_staff_alert after insert on reviews for each row execute function app.sa_review();

create or replace function app.sa_toll() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  begin
    perform app.staff_alert('toll_received', 'toll', new.id, 'new', 'Toll or ticket received: ' || coalesce(new.plate, 'unknown plate'),
      coalesce(new.authority, '') || ' ' || app.fmt_money(new.amount_cents), jsonb_build_object('path_admin', '/admin/tolls', 'path_staff', '/staff/tolls'));
  exception when others then
    raise warning 'toll alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists toll_tickets_z_staff_alert on toll_tickets;
create trigger toll_tickets_z_staff_alert after insert on toll_tickets for each row execute function app.sa_toll();

create or replace function app.sa_application() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  begin
    if app.email_is_test(new.email) then return null; end if;
    perform app.staff_alert('application_new', 'job_application', new.id, 'new', 'New job application: ' || coalesce(new.full_name, 'someone'),
      coalesce(new.profile_name, ''), jsonb_build_object('path_admin', '/admin/hiring'));
  exception when others then
    raise warning 'application alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists job_applications_z_staff_alert on job_applications;
create trigger job_applications_z_staff_alert after insert on job_applications for each row execute function app.sa_application();

create or replace function app.sa_usage() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  begin
    if new.level < 80 and new.included > 0 and (new.used / new.included) < 0.8 then return null; end if;
    perform app.staff_alert('usage_80', 'usage_alert', new.id, 'l' || new.level, 'Usage: ' || new.service || ' at level ' || new.level,
      format('%s of %s used this period', new.used, new.included), jsonb_build_object('path_admin', '/admin/settings/usage'));
  exception when others then
    raise warning 'usage alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists usage_alerts_z_staff_alert on usage_alerts;
create trigger usage_alerts_z_staff_alert after insert on usage_alerts for each row execute function app.sa_usage();

create or replace function app.sa_field_job() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_line text;
  v_rule text;
begin
  begin
    v_line := replace(new.kind, '_', ' ') || coalesce(', ' || app.vehicle_name(new.vehicle_id), '') || coalesce(', ' || app.fmt_at(new.scheduled_at), '');
    if tg_op = 'INSERT' or (old.assigned_to is distinct from new.assigned_to and new.assigned_to is not null) then
      if new.assigned_to is not null then
        perform app.staff_alert('job_assigned', 'field_job', new.id, coalesce(new.assigned_to::text, 'x'), 'Job assigned: ' || v_line,
          coalesce('To ' || (select u.full_name from users u where u.id = new.assigned_to), ''), jsonb_build_object('assigned_to', new.assigned_to, 'path_admin', '/admin/staff', 'path_staff', '/staff/field'));
      end if;
    end if;
    if tg_op = 'UPDATE' and old.status is distinct from new.status and new.status in ('in_progress', 'done') then
      v_rule := case new.status when 'in_progress' then 'job_started' else 'job_done' end;
      perform app.staff_alert(v_rule, 'field_job', new.id, new.status, case new.status when 'in_progress' then 'Job started: ' else 'Job finished: ' end || v_line,
        coalesce('By ' || (select u.full_name from users u where u.id = new.assigned_to), ''), jsonb_build_object('path_admin', '/admin/staff', 'path_staff', '/staff/field'));
    end if;
  exception when others then
    raise warning 'job alert not made for %: %', new.id, sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists field_jobs_z_staff_alert on field_jobs;
create trigger field_jobs_z_staff_alert after insert or update of assigned_to, status on field_jobs for each row execute function app.sa_field_job();

-- ================================================================ 6. the job (every 5 minutes)
create or replace function app.job_staff_alerts(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  r record;
  v_hour integer := app.local_hour(p_now);
  v_day text := app.local_date(p_now)::text;
  v_today date := app.local_date(p_now);
  n_late integer := 0; n_offer integer := 0; n_esc integer := 0; n_brief integer := 0;
  v_p integer; v_r integer; v_o integer; v_q integer; v_money bigint; v_cnt integer; v_made integer; v_urgent integer;
begin
  -- field jobs 15 minutes past their time and not started
  for r in select j.* from field_jobs j where j.status in ('scheduled', 'acknowledged') and j.scheduled_at < p_now - interval '15 minutes' and j.scheduled_at > p_now - interval '1 day' loop
    if app.staff_alert('job_late', 'field_job', r.id, 'late', 'Job running late: ' || replace(r.kind, '_', ' ') || coalesce(', ' || app.vehicle_name(r.vehicle_id), ''),
         'Was due ' || app.fmt_at(r.scheduled_at) || ' and has not started.', jsonb_build_object('assigned_to', r.assigned_to, 'path_admin', '/admin/staff', 'path_staff', '/staff/field')) is not null then n_late := n_late + 1; end if;
  end loop;
  -- offers that expire within the hour and are unanswered
  for r in select b.* from bookings b where b.status = 'offered' and b.offer_expires_at > p_now and b.offer_expires_at <= p_now + interval '1 hour' and not coalesce(b.is_placeholder, false) loop
    if app.staff_alert('offer_expiring', 'booking', r.id, to_char(r.offer_expires_at, 'YYYYMMDDHH24MI'), 'Offer expires within the hour: ' || app.sa_booking_line(r),
         'Expires ' || app.fmt_at(r.offer_expires_at), app.sa_booking_paths(r)) is not null then n_offer := n_offer + 1; end if;
  end loop;
  -- an urgent alert nobody opened goes to the Admins
  if s.alert_escalate_enabled then
    for r in select n.id, n.title, n.body, u.full_name from notifications n join users u on u.id = n.user_id
              where n.code in ('staff_alert_urgent', 'staff_lead_new', 'staff_owner_lead_new') and n.read_at is null
                and n.created_at < p_now - make_interval(mins => s.alert_escalate_minutes) and n.created_at > p_now - interval '1 day'
                and not app.user_is_admin(n.user_id) and not app.staff_is_test(n.user_id) loop
      if app.staff_alert('escalation', 'notification', r.id, 'esc', 'Not opened: ' || r.title,
           format('Sent to %s %s minutes ago. %s', r.full_name, s.alert_escalate_minutes, coalesce(r.body, ''))) is not null then n_esc := n_esc + 1; end if;
    end loop;
  end if;
  -- the morning brief and the evening wrap
  if s.alert_brief_enabled and v_hour in (8, 21) then
    select count(*) filter (where b.status = 'confirmed' and app.local_date(b.pickup_at) = v_today),
           count(*) filter (where b.status = 'on_rent' and app.local_date(b.return_at) = v_today),
           count(*) filter (where b.status = 'on_rent' and b.return_at < p_now),
           count(*) filter (where b.status = 'requested'),
           count(*) filter (where app.local_date(b.created_at) = v_today)
      into v_p, v_r, v_o, v_q, v_made from bookings b where not coalesce(b.is_placeholder, false) and b.booking_type <> 'owner';
    if v_hour = 8 then
      if app.staff_alert('morning_brief_admin', 'brief', null, v_day, 'Good morning: ' || v_p || ' pickups, ' || v_r || ' returns today',
           format('%s cars overdue. %s open requests.', v_o, v_q), jsonb_build_object('path_admin', '/admin/bookings')) is not null then n_brief := n_brief + 1; end if;
      for r in select sp.user_id, sp.va_function::text fn from staff_profiles sp join users u on u.id = sp.user_id and u.status = 'active'
                where sp.staff_type = 'va' and sp.is_active and sp.va_function::text in ('cs', 'sales', 'fleet') and not app.staff_is_test(sp.user_id) loop
        if app.staff_alert('morning_brief_staff', 'brief', r.user_id, v_day,
             case r.fn when 'fleet' then format('Good morning: %s pickups, %s returns today', v_p, v_r) else format('Good morning: %s open requests', v_q) end,
             case r.fn when 'fleet' then format('%s cars overdue.', v_o) else format('%s pickups today.', v_p) end,
             jsonb_build_object('assigned_to', r.user_id, 'path_staff', '/staff')) is not null then n_brief := n_brief + 1; end if;
      end loop;
    else
      select coalesce(sum(p.amount_cents), 0), count(*) into v_money, v_cnt from payments p
       where p.status = 'succeeded' and p.kind in ('charge', 'capture') and app.local_date(p.created_at) = v_today;
      select count(*) into v_urgent from tasks t where t.status in ('open', 'in_progress') and t.priority = 'urgent';
      if app.staff_alert('evening_wrap', 'brief', null, v_day, 'Evening wrap: ' || app.fmt_money(v_money) || ' in, ' || v_made || ' bookings made',
           format('%s overdue cars. %s urgent tasks open.', v_o, v_urgent), jsonb_build_object('path_admin', '/admin/overview')) is not null then n_brief := n_brief + 1; end if;
      perform app.staff_alert('cash_summary', 'brief', null, v_day, 'Cash today: ' || app.fmt_money(v_money), v_cnt || ' payments received', jsonb_build_object('path_admin', '/admin/payments'));
    end if;
  end if;
  return format('late jobs %s, offers %s, escalated %s, briefs %s', n_late, n_offer, n_esc, n_brief);
end $$;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-staff-alerts', '*/5 * * * *', 'select app.job_staff_alerts()');
  end if;
end $$;

-- ================================================================ 7. privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['staff_alert_users', 'staff_alert', 'sa_booking_line', 'sa_booking_paths', 'sa_booking_status', 'sa_booking_alert', 'sa_offer_sent',
              'sa_outbox_mirror', 'sa_payment', 'sa_refund', 'sa_review', 'sa_toll', 'sa_application', 'sa_usage', 'sa_field_job', 'job_staff_alerts',
              'notification_recipients_pre0462', 'ntf_payload_pre0462', 'lead_alert_emit'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
