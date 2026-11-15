-- 2960 (release 48): every alert opens the exact record it is about.
--
-- The owner's report (Nov 14): "most aren't leading anywhere". A sample of 80 live Admin alerts landed on bare pages:
-- the Admin home ("<renter> replied about booking CC-x", "<role> end of day: N items open"), /admin/staff ("Job running
-- late: handover, <car>", "Quiz passed: <name>"), /admin/academy (lessons finished, quizzes), /admin/live ("Hot visitor:
-- <name>"), /admin/unanswered ("<name> is waiting for an answer"), and the bare Listings, Messages and Chat lists.
-- The causes:
--   * the alert rules write one generic page per rule (path_admin '/admin/staff', '/admin/academy', ...); the notice
--     carries the record (entity and id) but 2904 used it only when the page was "/" or a home page;
--   * app.alert_record_path (2904) knew bookings, leads, cars, owners, tolls, field jobs, applications and bug reports
--     only: a message, a chat, a phone conversation, a visitor, a quiz, a lesson, a staff member, a shift, an investment
--     or an escalated alert gave nothing, so the home page;
--   * notices written before release 30 carry the old staff addresses (/va/cs/bookings/CC-x), which are no page now;
--   * the "latest alert" pop-up (server_alert_latest) used the stored address as it was, not the viewer's page.
-- Now app.alert_target gives the record's own page (and tab) in the viewer's portal for every kind of record a notice
-- is written for (app.alert_entity_kind lists them; the test 99_r48_alert_targets checks every kind the code writes).
-- A bare list page or home page gives way to the record whenever the notice names one, unless the notice is about a
-- list (a digest, a job run, a payout run, ...). End of day digests open the To do list of that role. The pages honour
-- the address: the field jobs board opens and marks ?job= and ?slot=, Visitors opens ?id= (Live now and Chat).
-- Unread notices are repointed. No applied migration is edited: functions are patched in place (the patch refuses when
-- the text it changes is not found) or new.
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '2960: the text to change was not found in %: %', p_sig, left(p_old, 160);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the pages each portal has, one list for both checks
create or replace function app.alert_routes() returns text[]
language sql immutable set search_path = public, app as $$
  select array[
    '^/admin$', '^/admin/academy$', '^/admin/academy/learn$', '^/admin/academy/learn/[^/]+/[^/]+$', '^/admin/academy/sections/[^/]+$', '^/admin/academy/staff/[^/]+$', '^/admin/alerts$', '^/admin/applications$', '^/admin/applications/[^/]+$', '^/admin/audit$', '^/admin/bookings$', '^/admin/bookings/[^/]+$', '^/admin/bookings/[^/]+/accident-card$', '^/admin/bookings/[^/]+/deposit-review$', '^/admin/bookings/[^/]+/handover/[^/]+$', '^/admin/bookings/[^/]+/report$', '^/admin/bookings/[^/]+/rideshare$', '^/admin/bookings/[^/]+/sign-now$', '^/admin/bookings/new$', '^/admin/bookings/past-trips$', '^/admin/bug-reports$', '^/admin/bug-reports/[^/]+$', '^/admin/calendar$', '^/admin/calendar-sync$', '^/admin/chat$', '^/admin/chauffeur$', '^/admin/damages$', '^/admin/damages/[^/]+$', '^/admin/debits$', '^/admin/deposit-reviews$', '^/admin/expenses$', '^/admin/field-jobs$', '^/admin/government-forms/[^/]+$', '^/admin/guide$', '^/admin/guide/[^/]+$', '^/admin/hiring$', '^/admin/hiring/[^/]+$', '^/admin/incidents$', '^/admin/incidents/[^/]+$', '^/admin/insurer-invoices$', '^/admin/insurers$', '^/admin/insurers/[^/]+$', '^/admin/investors$', '^/admin/investors/[^/]+$', '^/admin/investors/deck$', '^/admin/invoices$', '^/admin/invoices/[^/]+$', '^/admin/invoices/new$', '^/admin/kpis$', '^/admin/leads$', '^/admin/listings$', '^/admin/listings/[^/]+$', '^/admin/live$', '^/admin/live-map$', '^/admin/live/history$', '^/admin/live/history/[^/]+$', '^/admin/live/signals$', '^/admin/logs$', '^/admin/maintenance$', '^/admin/marketing$', '^/admin/marketing/ads$', '^/admin/marketing/channels$', '^/admin/marketing/emails$', '^/admin/marketing/events$', '^/admin/marketing/listings$', '^/admin/marketing/marketplace$', '^/admin/marketing/owner-pipeline$', '^/admin/marketing/recruit$', '^/admin/marketing/recruit/[^/]+$', '^/admin/marketing/report$', '^/admin/marketing/seo$', '^/admin/marketing/social$', '^/admin/messages$', '^/admin/money$', '^/admin/money/commissions$', '^/admin/money/field-pay$', '^/admin/money/kickbacks$', '^/admin/money/model$', '^/admin/no-access$', '^/admin/offers/new$', '^/admin/overview$', '^/admin/owner-forms$', '^/admin/owner-money$', '^/admin/owners$', '^/admin/owners/[^/]+$', '^/admin/owners/add-car$', '^/admin/partners$', '^/admin/partners/[^/]+$', '^/admin/payments$', '^/admin/payouts$', '^/admin/portals$', '^/admin/reconciliation$', '^/admin/referral-partners$', '^/admin/referral-partners/[^/]+$', '^/admin/renters$', '^/admin/renters/[^/]+$', '^/admin/reports$', '^/admin/requests$', '^/admin/reviews$', '^/admin/sales-leads$', '^/admin/sales-leads/[^/]+$', '^/admin/schedules$', '^/admin/search$', '^/admin/settings$', '^/admin/settings/[^/]+$', '^/admin/settings/call-helper$', '^/admin/settings/coverage-affiliate$', '^/admin/settings/guides$', '^/admin/settings/guides/[^/]+$', '^/admin/settings/meta-publishing$', '^/admin/settings/partners$', '^/admin/settings/partners/[^/]+$', '^/admin/settings/profile$', '^/admin/settings/rewards$', '^/admin/settings/terms$', '^/admin/settings/usage$', '^/admin/similar-cars$', '^/admin/staff$', '^/admin/staff/[^/]+/sales$', '^/admin/staff/[^/]+/scorecard$', '^/admin/statements$', '^/admin/statements/[^/]+$', '^/admin/style-guide$', '^/admin/tasks$', '^/admin/timesheet$', '^/admin/tolls$', '^/admin/tolls/[^/]+$', '^/admin/tolls/import$', '^/admin/tolls/new$', '^/admin/tolls/profiles$', '^/admin/tolls/read$', '^/admin/tolls/read/[^/]+$', '^/admin/townhall$', '^/admin/unanswered$', '^/admin/vehicles$', '^/admin/vehicles/[^/]+$', '^/admin/vehicles/bulk-rates$', '^/admin/vehicles/import-photos$', '^/admin/vehicles/incident-cards$', '^/admin/vehicles/new$', '^/admin/vehicles/samples$', '^/admin/vehicles/tracking$', '^/admin/visitors$',
    '^/admin/approvals$', '^/admin/disputes/[^/]+$', '^/admin/fleet$', '^/admin/jobs$', '^/admin/reports/weekly$',
    '^/staff$', '^/staff/academy$', '^/staff/academy/[^/]+/[^/]+$', '^/staff/addons$', '^/staff/alerts$', '^/staff/bookings$', '^/staff/bookings/[^/]+$', '^/staff/bookings/[^/]+/accident-card$', '^/staff/bookings/[^/]+/deposit-review$', '^/staff/bookings/[^/]+/handover/[^/]+$', '^/staff/bookings/[^/]+/report$', '^/staff/bookings/[^/]+/rideshare$', '^/staff/bookings/[^/]+/sign-now$', '^/staff/bookings/new$', '^/staff/bug-reports$', '^/staff/calendar$', '^/staff/calendar-sync$', '^/staff/card-coverage$', '^/staff/cars$', '^/staff/chat$', '^/staff/chauffeur$', '^/staff/checks$', '^/staff/deposit-reviews$', '^/staff/field$', '^/staff/field-hours$', '^/staff/field-spending$', '^/staff/field/guide$', '^/staff/field/help$', '^/staff/field/help/[^/]+$', '^/staff/field/help/[^/]+/sign$', '^/staff/field/hours$', '^/staff/field/jobs/[^/]+$', '^/staff/field/jobs/[^/]+/sign-now$', '^/staff/field/map$', '^/staff/field/now$', '^/staff/field/pay$', '^/staff/field/profile$', '^/staff/field/referrals$', '^/staff/field/rentals/new$', '^/staff/field/report$', '^/staff/field/sales$', '^/staff/field/shifts$', '^/staff/field/sign$', '^/staff/field/sign/[^/]+$', '^/staff/field/training$', '^/staff/fleet$', '^/staff/fleet/calls$', '^/staff/fleet/map$', '^/staff/game-leads$', '^/staff/government-forms$', '^/staff/government-forms/[^/]+$', '^/staff/guide$', '^/staff/hours$', '^/staff/leads$', '^/staff/listings$', '^/staff/listings/[^/]+$', '^/staff/listings/import-photos$', '^/staff/live$', '^/staff/maintenance$', '^/staff/marketing$', '^/staff/marketing/emails$', '^/staff/marketing/seo$', '^/staff/marketplace$', '^/staff/messages$', '^/staff/money$', '^/staff/my-sales$', '^/staff/no-access$', '^/staff/offers/new$', '^/staff/owner-forms$', '^/staff/owner-leads$', '^/staff/owner-money$', '^/staff/owner-pipeline$', '^/staff/owners$', '^/staff/owners/[^/]+$', '^/staff/owners/add-car$', '^/staff/partners$', '^/staff/partners/[^/]+$', '^/staff/past-trips$', '^/staff/payments$', '^/staff/payroll$', '^/staff/profile$', '^/staff/quotes/new$', '^/staff/reconciliation$', '^/staff/referral-partners$', '^/staff/referral-partners/[^/]+$', '^/staff/renters$', '^/staff/requests$', '^/staff/review-requests$', '^/staff/review/[^/]+$', '^/staff/reviews$', '^/staff/sales-leads$', '^/staff/sales-leads/[^/]+$', '^/staff/sales-start$', '^/staff/schedule$', '^/staff/scorecard$', '^/staff/sign$', '^/staff/sign/[^/]+$', '^/staff/similar-cars$', '^/staff/tasks/[^/]+$', '^/staff/timesheet$', '^/staff/today$', '^/staff/tolls$', '^/staff/tolls/profiles$', '^/staff/tolls/read$', '^/staff/tolls/read/[^/]+$', '^/staff/townhall$', '^/staff/turo$', '^/staff/unanswered$', '^/staff/vehicles/[^/]+$', '^/staff/vehicles/incident-cards$', '^/staff/verify/[^/]+$', '^/staff/visitors$', '^/staff/welcome$'
  ]
$$;

select pg_temp.patch_fn('app.alert_route_ok(text)'::regprocedure,
  (select substring(pg_get_functiondef('app.alert_route_ok(text)'::regprocedure) from 'unnest\((array\[.*\])\) r where'))::text,
  'app.alert_routes()');

-- a page with no record in its address (a list, a board, a home page)
create or replace function app.alert_route_static(p_path text) returns boolean
language sql immutable set search_path = public, app as $$
  select exists (select 1 from unnest(app.alert_routes()) r where position('[^/]+' in r) = 0 and p_path ~ r)
     and not exists (select 1 from unnest(app.alert_routes()) r where position('[^/]+' in r) > 0 and p_path ~ r)
$$;

-- ================================================================ 2. the kinds of record a staff notice is written for
-- booking: the record belongs to a booking (its table has booking_id); record: it has a page of its own (or a place on a
-- page); list: the notice is about a list or the whole business (a digest, a run), so a list page is right.
create or replace function app.alert_entity_kind(p_entity text) returns text
language sql immutable set search_path = public, app as $$
  select case
    when p_entity in ('booking', 'payment', 'refund', 'deposit', 'booking_change', 'booking_change_request', 'booking_extension', 'booking_override',
                      'incident', 'dispute', 'review', 'insurer_invoice', 'rental_agreement', 'verification_upload', 'condition_report',
                      'calendar_conflict', 'toll', 'toll_ticket') then 'booking'
    when p_entity in ('message', 'chat', 'chat_conversation', 'phone_thread', 'visitor', 'contact_capture', 'lead',
                      'vehicle', 'vehicle_exit', 'vehicle_service_record', 'field_car_update', 'field_prep_task', 'field_spend', 'listing_intake',
                      'listing_similarity_flag', 'owner', 'owner_payout_account', 'owner_debit', 'owner_debit_attempt', 'owner_debit_notice',
                      'owner_agreement_form', 'owner_invoice', 'field_job', 'field_shift_slot', 'field_shift_offer', 'bug_report', 'job_application',
                      'hiring_alert', 'academy_attempt', 'academy_lesson', 'user', 'users', 'staff', 'account_deletion', 'investment',
                      'investment_agreement', 'notification', 'task') then 'record'
    when p_entity in ('alert_group', 'brief', 'deploy', 'job_run', 'payout_run', 'owner_debit_run', 'field_pay_run', 'field_pay_line', 'field_shift',
                      'fleet_count', 'sign_in', 'site_alert', 'site_selfqa_run', 'email_suppression', 'sms_opt_out', 'townhall_deck',
                      'townhall_meeting', 'interview_day', 'lead_alert', 'calendar_feed', 'company_statement', 'staff_commission_payout',
                      'tracker_command') then 'list'
  end
$$;

-- the table that holds each kind (the test samples real rows from it)
create or replace function app.alert_entity_table(p_entity text) returns text
language sql immutable set search_path = public, app as $$
  select case p_entity
    when 'booking' then 'bookings' when 'payment' then 'payments' when 'refund' then 'refunds' when 'deposit' then 'deposits'
    when 'booking_change' then 'booking_change_requests' when 'booking_change_request' then 'booking_change_requests'
    when 'booking_extension' then 'booking_extensions' when 'booking_override' then 'booking_overrides' when 'incident' then 'incidents'
    when 'dispute' then 'disputes' when 'review' then 'reviews' when 'insurer_invoice' then 'insurer_invoices'
    when 'rental_agreement' then 'rental_agreements' when 'verification_upload' then 'verification_uploads'
    when 'condition_report' then 'condition_reports' when 'calendar_conflict' then 'calendar_conflicts'
    when 'toll' then 'toll_tickets' when 'toll_ticket' then 'toll_tickets'
    when 'message' then 'messages' when 'chat' then 'chat_conversations' when 'chat_conversation' then 'chat_conversations'
    when 'phone_thread' then 'phone_threads' when 'visitor' then 'visitor_sessions' when 'contact_capture' then 'contact_captures'
    when 'lead' then 'leads' when 'vehicle' then 'vehicles' when 'vehicle_exit' then 'vehicle_exits'
    when 'vehicle_service_record' then 'vehicle_service_records' when 'field_car_update' then 'field_car_updates'
    when 'field_prep_task' then 'field_prep_tasks' when 'field_spend' then 'field_spends' when 'listing_intake' then 'listing_intakes'
    when 'listing_similarity_flag' then 'listing_similarity_flags' when 'owner' then 'owners' when 'owner_payout_account' then 'owner_payout_accounts'
    when 'owner_debit' then 'owner_debit_attempts' when 'owner_debit_attempt' then 'owner_debit_attempts' when 'owner_debit_notice' then 'owner_debit_notices'
    when 'owner_agreement_form' then 'owner_agreement_forms' when 'owner_invoice' then 'owner_invoices' when 'field_job' then 'field_jobs'
    when 'field_shift_slot' then 'field_shift_slots' when 'field_shift_offer' then 'field_shift_offers' when 'bug_report' then 'bug_reports'
    when 'job_application' then 'job_applications' when 'hiring_alert' then 'job_applications' when 'academy_attempt' then 'academy_attempts'
    when 'academy_lesson' then 'academy_lessons' when 'user' then 'users' when 'users' then 'users' when 'staff' then 'users'
    when 'account_deletion' then 'account_deletion_requests' when 'investment' then 'investments'
    when 'investment_agreement' then 'investment_agreements' when 'notification' then 'notifications' when 'task' then 'tasks'
  end
$$;

-- the booking section a kind of record lives in (when the alert's own code or rule names none)
create or replace function app.alert_entity_tab(p_entity text) returns text
language sql immutable set search_path = public, app as $$
  select case
    when p_entity in ('message', 'chat', 'chat_conversation', 'phone_thread') then 'activity'
    when p_entity in ('payment', 'refund', 'deposit', 'dispute', 'insurer_invoice') then 'money'
    when p_entity in ('incident', 'booking_change', 'booking_change_request', 'booking_extension', 'booking_override', 'review') then 'extras'
    when p_entity in ('rental_agreement', 'verification_upload') then 'documents'
    when p_entity in ('condition_report', 'field_spend') then 'car'
  end
$$;

-- ================================================================ 3. the record's page for this viewer
create or replace function app.alert_target(p_user uuid, p_admin boolean, p_field_only boolean, p_entity text, p_id uuid,
                                            p_rule text default null, p_payload jsonb default null) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_portal text := case when p_admin then '/admin' else '/staff' end;
  v_tbl text := app.alert_entity_table(p_entity);
  v_kind text := app.alert_entity_kind(p_entity);
  v_bk uuid;
  v_num text;
  v_id uuid;
  v_id2 uuid;
  v_txt text;
  v_chat uuid;
  v_renter uuid;
  n notifications;
begin
  if p_entity is null or p_id is null or v_kind is distinct from 'booking' and v_kind is distinct from 'record' then return null; end if;

  -- the Admin's own page for a few records that belong to a booking
  if p_admin then
    if p_entity in ('toll', 'toll_ticket') and exists (select 1 from toll_tickets t where t.id = p_id) then return '/admin/tolls/' || p_id; end if;
    if p_entity = 'dispute' and exists (select 1 from disputes d where d.id = p_id) then return '/admin/disputes/' || p_id; end if;
    if p_entity = 'incident' then
      select i.incident_number::text into v_txt from incidents i where i.id = p_id;
      if v_txt is not null then return '/admin/incidents/' || v_txt; end if;
    end if;
  end if;

  -- a record of a booking: the booking, in the section it lives in
  if v_kind = 'booking' or p_entity in ('message', 'field_spend', 'task') then
    if p_entity = 'booking' then v_bk := p_id;
    else execute format('select booking_id from %I where id = $1', v_tbl) into v_bk using p_id;
    end if;
    select b.booking_number into v_num from bookings b where b.id = v_bk;
    if v_num is not null then
      return v_portal || '/bookings/' || v_num || coalesce('?tab=' || app.alert_entity_tab(p_entity), '');
    end if;
    if p_entity in ('toll', 'toll_ticket') and not p_admin and exists (select 1 from toll_tickets t where t.id = p_id) then return '/staff/tolls?bucket=unmatched'; end if;
    if v_kind = 'booking' then return null; end if;
  end if;

  case
  when p_entity = 'message' then
    select m.owner_id, m.renter_id into v_id, v_id2 from messages m where m.id = p_id;
    if v_id is not null then return v_portal || '/owners/' || v_id; end if;
    if v_id2 is not null and p_admin then return '/admin/renters/' || v_id2; end if;
  when p_entity in ('chat', 'chat_conversation') then
    if not p_field_only and exists (select 1 from chat_conversations c where c.id = p_id) then return v_portal || '/visitors?view=chat&id=' || p_id; end if;
  when p_entity = 'phone_thread' then
    if not p_field_only and exists (select 1 from phone_threads t where t.id = p_id) then return v_portal || '/visitors?view=chat&inbox=phone&id=' || p_id; end if;
  when p_entity in ('visitor', 'contact_capture') then
    if p_entity = 'contact_capture' then
      -- the lead it made, else the chat it came from, else the renter, else the visit
      select c.lead_id, c.visitor_id, c.chat_id, c.renter_id into v_id, v_id2, v_chat, v_renter from contact_captures c where c.id = p_id;
      if v_id is not null and not p_field_only then return v_portal || '/sales-leads/' || v_id; end if;
      if v_chat is not null and not p_field_only and exists (select 1 from chat_conversations c where c.id = v_chat) then return v_portal || '/visitors?view=chat&id=' || v_chat; end if;
      if v_renter is not null and p_admin then return '/admin/renters/' || v_renter; end if;
    else
      v_id2 := p_id;
    end if;
    -- the visit: the session the alert names, else the visitor's latest
    v_id := case when coalesce(p_payload ->> 'session_id', '') ~ '^[0-9a-f-]{36}$' then (p_payload ->> 'session_id')::uuid end;
    if v_id is null or not exists (select 1 from visitor_sessions s where s.id = v_id) then
      select s.id into v_id from visitor_sessions s where s.visitor_id = v_id2 order by s.started_at desc nulls last limit 1;
    end if;
    if v_id is not null and not p_field_only then
      return case when p_admin then '/admin/live/history/' || v_id else '/staff/visitors?id=' || v_id end;
    end if;
  when p_entity = 'lead' then
    if exists (select 1 from leads l where l.id = p_id) then return v_portal || '/sales-leads/' || p_id; end if;
  when p_entity in ('vehicle', 'vehicle_exit', 'vehicle_service_record', 'field_car_update', 'field_prep_task', 'field_spend', 'listing_intake', 'listing_similarity_flag') then
    if p_entity = 'vehicle' then v_id := p_id; else execute format('select vehicle_id from %I where id = $1', v_tbl) into v_id using p_id; end if;
    if v_id is not null and exists (select 1 from vehicles v where v.id = v_id) then
      return v_portal || '/vehicles/' || v_id || case when p_entity = 'listing_intake' then '?tab=listing' else '' end;
    end if;
  when p_entity in ('owner', 'owner_payout_account', 'owner_debit', 'owner_debit_attempt', 'owner_debit_notice', 'owner_agreement_form', 'owner_invoice') then
    if p_entity = 'owner' then v_id := p_id; else execute format('select owner_id from %I where id = $1', v_tbl) into v_id using p_id; end if;
    v_id := coalesce(v_id, case when coalesce(p_payload ->> 'owner_id', '') ~ '^[0-9a-f-]{36}$' then (p_payload ->> 'owner_id')::uuid end);
    if v_id is not null and exists (select 1 from owners o where o.id = v_id) then return v_portal || '/owners/' || v_id; end if;
  when p_entity = 'field_job' then
    if exists (select 1 from field_jobs j where j.id = p_id) then
      return case when p_admin then '/admin/field-jobs?job=' || p_id when p_field_only then '/staff/field/jobs/' || p_id else '/staff/fleet?job=' || p_id end;
    end if;
  when p_entity in ('field_shift_slot', 'field_shift_offer') then
    if p_entity = 'field_shift_slot' then v_id := p_id; else select o.slot_id into v_id from field_shift_offers o where o.id = p_id; end if;
    if v_id is not null and exists (select 1 from field_shift_slots s where s.id = v_id) then
      return case when p_admin then '/admin/field-jobs?slot=' || v_id when p_field_only then '/staff/field/shifts' else '/staff/fleet?slot=' || v_id end;
    end if;
  when p_entity = 'bug_report' then
    if exists (select 1 from bug_reports r where r.id = p_id) then return case when p_admin then '/admin/bug-reports/' || p_id else '/staff/bug-reports' end; end if;
  when p_entity in ('job_application', 'hiring_alert') then
    if p_admin and exists (select 1 from job_applications a where a.id = p_id) then return '/admin/hiring/' || p_id; end if;
  when p_entity in ('academy_attempt', 'academy_lesson') then
    if p_entity = 'academy_attempt' then
      select a.user_id into v_id from academy_attempts a where a.id = p_id;
    else
      v_txt := coalesce(p_payload ->> 'staff_user_id', substring(coalesce(p_payload ->> 'kind', '') from ':([0-9a-f-]{36})$'));
      v_id := case when v_txt ~ '^[0-9a-f-]{36}$' then v_txt::uuid end;
    end if;
    if p_admin and v_id is not null and exists (select 1 from users u where u.id = v_id) then return '/admin/academy/staff/' || v_id; end if;
    if not p_admin then return '/staff/academy'; end if;
  when p_entity in ('user', 'users', 'staff') then
    if p_admin and exists (select 1 from users u where u.id = p_id) then
      if coalesce(p_rule, '') like 'academy%' then return '/admin/academy/staff/' || p_id; end if;
      if coalesce(p_rule, '') like 'townhall%' then return '/admin/townhall'; end if;
      if exists (select 1 from staff_profiles sp where sp.user_id = p_id) and coalesce(p_rule, '') not in ('admin_new_device', 'staff_onboarding_approve') then
        return '/admin/staff/' || p_id || '/scorecard';
      end if;
    end if;
  when p_entity = 'account_deletion' then
    select r.id into v_id from account_deletion_requests d join renters r on r.user_id = d.user_id where d.id = p_id;
    if p_admin and v_id is not null then return '/admin/renters/' || v_id; end if;
  when p_entity in ('investment', 'investment_agreement') then
    execute format('select investor_id from %I where id = $1', v_tbl) into v_id using p_id;
    if p_admin and v_id is not null then return '/admin/investors/' || v_id; end if;
  when p_entity = 'notification' then
    -- an escalated alert: the page of the alert it escalates, for this viewer
    select * into n from notifications x where x.id = p_id;
    if n.id is not null and n.entity is distinct from 'notification' then
      return app.alert_path_for(p_user, n.url, n.code, n.entity, n.entity_id, n.event_id);
    end if;
  when p_entity = 'task' then
    if not p_admin and not p_field_only and exists (select 1 from tasks t where t.id = p_id) then return '/staff/tasks/' || p_id; end if;
    if p_admin then select t.queue::text into v_txt from tasks t where t.id = p_id; if v_txt is not null then return '/admin/tasks?queue=' || v_txt; end if; end if;
  else
    null;
  end case;
  return null;
end $$;

-- the old function (2904) answers with the new one
create or replace function app.alert_record_path(p_admin boolean, p_entity text, p_id uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select app.alert_target(null, p_admin, false, p_entity, p_id)
$$;

revoke all on function app.alert_routes() from public, anon, authenticated;
revoke all on function app.alert_route_static(text) from public, anon, authenticated;
revoke all on function app.alert_entity_kind(text) from public, anon, authenticated;
revoke all on function app.alert_entity_table(text) from public, anon, authenticated;
revoke all on function app.alert_entity_tab(text) from public, anon, authenticated;
revoke all on function app.alert_target(uuid, boolean, boolean, text, uuid, text, jsonb) from public, anon, authenticated;
grant execute on function app.alert_routes() to service_role;
grant execute on function app.alert_route_static(text) to service_role;
grant execute on function app.alert_entity_kind(text) to service_role;
grant execute on function app.alert_entity_table(text) to service_role;
grant execute on function app.alert_entity_tab(text) to service_role;
grant execute on function app.alert_target(uuid, boolean, boolean, text, uuid, text, jsonb) to service_role;

-- ================================================================ 4. the page for this viewer: the record wins over a list
select pg_temp.patch_fn('app.alert_path_for(uuid, text, text, text, uuid, bigint)'::regprocedure,
  $o$  v_rec text;
begin$o$,
  $n$  v_rec text;
  v_payload jsonb;
begin$n$);
select pg_temp.patch_fn('app.alert_path_for(uuid, text, text, text, uuid, bigint)'::regprocedure,
  $o$select e.payload ->> 'rule' into v_rule from app_events e where e.id = p_event_id;$o$,
  $n$select e.payload ->> 'rule', e.payload into v_rule, v_payload from app_events e where e.id = p_event_id;

  -- the staff addresses before release 30 (/va/cs/bookings/CC-1): the same page under /staff
  if v_path ~ '^/va(/|$)' then
    v_path := regexp_replace(v_path, '^/va(/(cs|fleet|finance|sales|field))?', '/staff');
  end if;$n$);
select pg_temp.patch_fn('app.alert_path_for(uuid, text, text, text, uuid, bigint)'::regprocedure,
  $o$  -- no page, or only the home page: the record's own page when the notice names one
  if v_path = '/' or v_path = v_portal or v_path = v_home or v_path !~ ('^' || v_portal || '(/|$)') or not app.alert_route_ok(v_path) then
    v_rec := app.alert_record_path(v_admin, p_entity, p_entity_id);
    if v_rec is not null then
      v_path := v_rec; v_query := ''; v_hash := '';$o$,
  $n$  -- an end of day digest: the To do list of that role (staff: their queue, the home page)
  if p_code like 'staff_digest_eod_%' and v_admin then
    v_path := '/admin/tasks'; v_hash := '';
    v_query := '?queue=' || case when p_code = 'staff_digest_eod_admin' then 'admin' else substr(p_code, length('staff_digest_eod_va_') + 1) end;
  end if;

  -- no page, the home page or a bare list: the record's own page when the notice names one (2960: a list too)
  if v_path = '/' or v_path = v_portal or v_path = v_home or v_path !~ ('^' || v_portal || '(/|$)') or not app.alert_route_ok(v_path)
     or (v_query = '' and v_hash = '' and app.alert_route_static(v_path)) then
    v_rec := app.alert_target(p_user, v_admin, v_field_only, p_entity, p_entity_id, v_rule, v_payload);
    if v_rec is not null then
      v_path := regexp_replace(v_rec, '\?.*$', ''); v_query := coalesce(substring(v_rec from '(\?.*)$'), ''); v_hash := '';$n$);

-- ================================================================ 5. the "latest alert" pop-up uses it too
select pg_temp.patch_fn('app.server_alert_latest(uuid)'::regprocedure,
  $o$'url', n.url,$o$,
  $n$'url', app.alert_path_for(p_user, n.url, n.code, n.entity, n.entity_id, n.event_id),$n$);

-- ================================================================ 6. the writers: a finished lesson names the person
select pg_temp.patch_fn('app.sa_academy_lesson()'::regprocedure,
  $o$jsonb_build_object('path_admin', '/admin/academy')$o$,
  $n$jsonb_build_object('path_admin', '/admin/academy/staff/' || u.id, 'staff_user_id', u.id)$n$);
select pg_temp.patch_fn('app.sa_academy_attempt()'::regprocedure,
  $o$jsonb_build_object('path_admin', '/admin/staff')$o$,
  $n$jsonb_build_object('path_admin', '/admin/academy/staff/' || u.id, 'staff_user_id', u.id)$n$);

-- ================================================================ 7. unread staff alerts already written: the exact page now
update notifications n
   set url = app.alert_path_for(n.user_id, n.url, n.code, n.entity, n.entity_id, n.event_id)
  from notification_catalogue c
 where c.code = n.code and c.audience like 'staff%' and n.read_at is null
   and n.url is distinct from app.alert_path_for(n.user_id, n.url, n.code, n.entity, n.entity_id, n.event_id);

comment on function app.alert_target(uuid, boolean, boolean, text, uuid, text, jsonb) is
  'The page of the record a staff alert is about, in the viewer''s portal (2960): the booking and its section, the conversation, the visit, the field job, the staff member, ...';
