-- 2904 (release 47): an alert opens the right page for the person who clicks it.
--
-- The owner's report (Nov 14): "When clicking on alerts, it often doesn't take you to the right page." The bell, the
-- Alerts pages and the phone alerts all open notifications.url (through app.push_path, 0300). That address is written once
-- for every recipient, so it was often wrong for the person who clicked it:
--   * staff pages sent to Admins (an Admin without a staff function lands on "no access"): the booking, request, return,
--     verification, fleet, toll and owner-form alerts written for the office (staff_late_return_alert,
--     staff_request_waiting, staff_deposit_release_due, staff_toll_ticket_unmatched, staff_expiry_watch, ...);
--   * Admin pages sent to staff (they land on "no access"): disputes, claims, payouts, the incidents list
--     (staff_dispute_opened, staff_incident_reported, staff_payouts_due, ...);
--   * alerts from the alert rules with only an Admin page: every staff recipient got the bare /staff home;
--   * links with an id that no page reads (/staff/tolls?ticket=...) and booking links without the section the alert is
--     about (a failed payment opened the overview, not Money);
--   * a link of ours written with the other host (www. or not) turned into "/" (the site's home page).
-- app.alert_path_for maps the stored address to the same page in THAT viewer's portal (pages that exist under web/src/app),
-- adds the booking section the alert is about, and falls back to the record's own page (from the notice's entity) when
-- the address is "/", a home page or a page the viewer's portal does not have. The feed (server_alert_feed) and the phone
-- alert (push_from_notice) both use it. Alerts from the rules now also carry the other portal's page when one is missing.
-- Notices for renters, owners and investors are not changed (app.push_path as before). No applied migration is edited:
-- the functions that change are patched in place, and the patch refuses when the text it changes is not found.
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '2904: the text to change was not found in %: %', p_sig, left(p_old, 160);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the pages each portal has (web/src/app, plus the old
-- Admin addresses next.config.ts redirects)
create or replace function app.alert_route_ok(p_path text) returns boolean
language sql immutable set search_path = public, app as $$
  select exists (select 1 from unnest(array[
    '^/admin$', '^/admin/academy$', '^/admin/academy/learn$', '^/admin/academy/learn/[^/]+/[^/]+$', '^/admin/academy/sections/[^/]+$', '^/admin/academy/staff/[^/]+$', '^/admin/alerts$', '^/admin/applications$', '^/admin/applications/[^/]+$', '^/admin/audit$', '^/admin/bookings$', '^/admin/bookings/[^/]+$', '^/admin/bookings/[^/]+/accident-card$', '^/admin/bookings/[^/]+/deposit-review$', '^/admin/bookings/[^/]+/handover/[^/]+$', '^/admin/bookings/[^/]+/report$', '^/admin/bookings/[^/]+/rideshare$', '^/admin/bookings/[^/]+/sign-now$', '^/admin/bookings/new$', '^/admin/bookings/past-trips$', '^/admin/bug-reports$', '^/admin/bug-reports/[^/]+$', '^/admin/calendar$', '^/admin/calendar-sync$', '^/admin/chat$', '^/admin/chauffeur$', '^/admin/damages$', '^/admin/damages/[^/]+$', '^/admin/debits$', '^/admin/deposit-reviews$', '^/admin/expenses$', '^/admin/field-jobs$', '^/admin/government-forms/[^/]+$', '^/admin/guide$', '^/admin/guide/[^/]+$', '^/admin/hiring$', '^/admin/hiring/[^/]+$', '^/admin/incidents$', '^/admin/incidents/[^/]+$', '^/admin/insurer-invoices$', '^/admin/insurers$', '^/admin/insurers/[^/]+$', '^/admin/investors$', '^/admin/investors/[^/]+$', '^/admin/investors/deck$', '^/admin/invoices$', '^/admin/invoices/[^/]+$', '^/admin/invoices/new$', '^/admin/kpis$', '^/admin/leads$', '^/admin/listings$', '^/admin/listings/[^/]+$', '^/admin/live$', '^/admin/live-map$', '^/admin/live/history$', '^/admin/live/history/[^/]+$', '^/admin/live/signals$', '^/admin/logs$', '^/admin/maintenance$', '^/admin/marketing$', '^/admin/marketing/ads$', '^/admin/marketing/channels$', '^/admin/marketing/emails$', '^/admin/marketing/events$', '^/admin/marketing/listings$', '^/admin/marketing/marketplace$', '^/admin/marketing/owner-pipeline$', '^/admin/marketing/recruit$', '^/admin/marketing/recruit/[^/]+$', '^/admin/marketing/report$', '^/admin/marketing/seo$', '^/admin/marketing/social$', '^/admin/messages$', '^/admin/money$', '^/admin/money/commissions$', '^/admin/money/field-pay$', '^/admin/money/kickbacks$', '^/admin/money/model$', '^/admin/no-access$', '^/admin/offers/new$', '^/admin/overview$', '^/admin/owner-forms$', '^/admin/owner-money$', '^/admin/owners$', '^/admin/owners/[^/]+$', '^/admin/owners/add-car$', '^/admin/partners$', '^/admin/partners/[^/]+$', '^/admin/payments$', '^/admin/payouts$', '^/admin/portals$', '^/admin/reconciliation$', '^/admin/referral-partners$', '^/admin/referral-partners/[^/]+$', '^/admin/renters$', '^/admin/renters/[^/]+$', '^/admin/reports$', '^/admin/requests$', '^/admin/reviews$', '^/admin/sales-leads$', '^/admin/sales-leads/[^/]+$', '^/admin/schedules$', '^/admin/search$', '^/admin/settings$', '^/admin/settings/[^/]+$', '^/admin/settings/call-helper$', '^/admin/settings/coverage-affiliate$', '^/admin/settings/guides$', '^/admin/settings/guides/[^/]+$', '^/admin/settings/meta-publishing$', '^/admin/settings/partners$', '^/admin/settings/partners/[^/]+$', '^/admin/settings/profile$', '^/admin/settings/rewards$', '^/admin/settings/terms$', '^/admin/settings/usage$', '^/admin/similar-cars$', '^/admin/staff$', '^/admin/staff/[^/]+/sales$', '^/admin/staff/[^/]+/scorecard$', '^/admin/statements$', '^/admin/statements/[^/]+$', '^/admin/style-guide$', '^/admin/tasks$', '^/admin/timesheet$', '^/admin/tolls$', '^/admin/tolls/[^/]+$', '^/admin/tolls/import$', '^/admin/tolls/new$', '^/admin/tolls/profiles$', '^/admin/tolls/read$', '^/admin/tolls/read/[^/]+$', '^/admin/townhall$', '^/admin/unanswered$', '^/admin/vehicles$', '^/admin/vehicles/[^/]+$', '^/admin/vehicles/bulk-rates$', '^/admin/vehicles/import-photos$', '^/admin/vehicles/incident-cards$', '^/admin/vehicles/new$', '^/admin/vehicles/samples$', '^/admin/vehicles/tracking$', '^/admin/visitors$',
    '^/admin/approvals$', '^/admin/disputes/[^/]+$', '^/admin/fleet$', '^/admin/jobs$', '^/admin/reports/weekly$',
    '^/staff$', '^/staff/academy$', '^/staff/academy/[^/]+/[^/]+$', '^/staff/addons$', '^/staff/alerts$', '^/staff/bookings$', '^/staff/bookings/[^/]+$', '^/staff/bookings/[^/]+/accident-card$', '^/staff/bookings/[^/]+/deposit-review$', '^/staff/bookings/[^/]+/handover/[^/]+$', '^/staff/bookings/[^/]+/report$', '^/staff/bookings/[^/]+/rideshare$', '^/staff/bookings/[^/]+/sign-now$', '^/staff/bookings/new$', '^/staff/bug-reports$', '^/staff/calendar$', '^/staff/calendar-sync$', '^/staff/card-coverage$', '^/staff/cars$', '^/staff/chat$', '^/staff/chauffeur$', '^/staff/checks$', '^/staff/deposit-reviews$', '^/staff/field$', '^/staff/field-hours$', '^/staff/field-spending$', '^/staff/field/guide$', '^/staff/field/help$', '^/staff/field/help/[^/]+$', '^/staff/field/help/[^/]+/sign$', '^/staff/field/hours$', '^/staff/field/jobs/[^/]+$', '^/staff/field/jobs/[^/]+/sign-now$', '^/staff/field/map$', '^/staff/field/now$', '^/staff/field/pay$', '^/staff/field/profile$', '^/staff/field/referrals$', '^/staff/field/rentals/new$', '^/staff/field/report$', '^/staff/field/sales$', '^/staff/field/shifts$', '^/staff/field/sign$', '^/staff/field/sign/[^/]+$', '^/staff/field/training$', '^/staff/fleet$', '^/staff/fleet/calls$', '^/staff/fleet/map$', '^/staff/game-leads$', '^/staff/government-forms$', '^/staff/government-forms/[^/]+$', '^/staff/guide$', '^/staff/hours$', '^/staff/leads$', '^/staff/listings$', '^/staff/listings/[^/]+$', '^/staff/listings/import-photos$', '^/staff/live$', '^/staff/maintenance$', '^/staff/marketing$', '^/staff/marketing/emails$', '^/staff/marketing/seo$', '^/staff/marketplace$', '^/staff/messages$', '^/staff/money$', '^/staff/my-sales$', '^/staff/no-access$', '^/staff/offers/new$', '^/staff/owner-forms$', '^/staff/owner-leads$', '^/staff/owner-money$', '^/staff/owner-pipeline$', '^/staff/owners$', '^/staff/owners/[^/]+$', '^/staff/owners/add-car$', '^/staff/partners$', '^/staff/partners/[^/]+$', '^/staff/past-trips$', '^/staff/payments$', '^/staff/payroll$', '^/staff/profile$', '^/staff/quotes/new$', '^/staff/reconciliation$', '^/staff/referral-partners$', '^/staff/referral-partners/[^/]+$', '^/staff/renters$', '^/staff/requests$', '^/staff/review-requests$', '^/staff/review/[^/]+$', '^/staff/reviews$', '^/staff/sales-leads$', '^/staff/sales-leads/[^/]+$', '^/staff/sales-start$', '^/staff/schedule$', '^/staff/scorecard$', '^/staff/sign$', '^/staff/sign/[^/]+$', '^/staff/similar-cars$', '^/staff/tasks/[^/]+$', '^/staff/timesheet$', '^/staff/today$', '^/staff/tolls$', '^/staff/tolls/profiles$', '^/staff/tolls/read$', '^/staff/tolls/read/[^/]+$', '^/staff/townhall$', '^/staff/turo$', '^/staff/unanswered$', '^/staff/vehicles/[^/]+$', '^/staff/vehicles/incident-cards$', '^/staff/verify/[^/]+$', '^/staff/visitors$', '^/staff/welcome$'
  ]) r where p_path ~ r)
$$;

-- ================================================================ 2. the booking section an alert is about
create or replace function app.alert_booking_tab(p_code text, p_rule text) returns text
language sql immutable set search_path = public, app as $$
  select case
    when p_code in ('staff_payment_failed', 'staff_offer_approved_paid', 'staff_cancellation_received', 'staff_deposit_release_due', 'staff_dispute_opened')
      or p_rule in ('payment_received', 'refund_issued', 'deposit_hold_failed', 'card_declined_pickup', 'deposit_reauth_failed', 'finance_hold_expiring',
                    'finance_deposit_return_due', 'finance_payment_due', 'extension_paid', 'deposit_released', 'sent:renter_balance_overdue',
                    'sent:renter_payment_failed', 'sent:renter_recovery_pay') then 'money'
    when p_code in ('staff_change_request_received', 'staff_change_proposal_answered', 'staff_extension_requested', 'staff_breakdown_reported', 'staff_incident_reported')
      or p_rule in ('date_change', 'accident_reported', 'insurer_claim_missing') then 'extras'
    when p_code = 'staff_identity_review'
      or p_rule in ('agreement_signed', 'agreement_unsigned_pickup', 'licence_review', 'insurance_missing', 'rideshare_docs_requested', 'sent:renter_agreement_ready') then 'documents'
    when p_code in ('staff_return_findings', 'staff_late_return_alert', 'staff_not_back', 'staff_not_back_admin', 'staff_pickup_unrecorded', 'staff_pickup_unrecorded_admin')
      or p_rule in ('booking_out', 'booking_back', 'booking_not_back', 'booking_no_show', 'return_fuel_km', 'handover_checklist_incomplete',
                    'sent:renter_late_return_first', 'sent:renter_late_return_final', 'sent:renter_return_due') then 'car'
    when p_code in ('staff_renter_replied', 'staff_chat_message') or p_rule = 'complaint_keyword' then 'activity'
  end
$$;

-- ================================================================ 3. the record's own page, from the notice's entity
create or replace function app.alert_record_path(p_admin boolean, p_entity text, p_id uuid) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_portal text := case when p_admin then '/admin' else '/staff' end;
  v_num text;
begin
  if p_entity is null or p_id is null then return null; end if;
  v_num := case p_entity
    when 'booking' then (select b.booking_number from bookings b where b.id = p_id)
    when 'payment' then (select b.booking_number from payments x join bookings b on b.id = x.booking_id where x.id = p_id)
    when 'refund' then (select b.booking_number from refunds x join bookings b on b.id = x.booking_id where x.id = p_id)
    when 'deposit' then (select b.booking_number from deposits x join bookings b on b.id = x.booking_id where x.id = p_id)
    when 'booking_change_request' then (select b.booking_number from booking_change_requests x join bookings b on b.id = x.booking_id where x.id = p_id)
    when 'incident' then (select b.booking_number from incidents x join bookings b on b.id = x.booking_id where x.id = p_id)
    when 'dispute' then (select b.booking_number from disputes x join bookings b on b.id = x.booking_id where x.id = p_id)
    when 'review' then (select b.booking_number from reviews x join bookings b on b.id = x.booking_id where x.id = p_id)
    when 'toll' then (select b.booking_number from toll_tickets x join bookings b on b.id = x.booking_id where x.id = p_id)
    when 'toll_ticket' then (select b.booking_number from toll_tickets x join bookings b on b.id = x.booking_id where x.id = p_id)
  end;
  if v_num is not null then return v_portal || '/bookings/' || v_num; end if;
  return case
    when p_entity = 'lead' and exists (select 1 from leads l where l.id = p_id) then v_portal || '/sales-leads/' || p_id
    when p_entity = 'vehicle' and exists (select 1 from vehicles v where v.id = p_id) then v_portal || '/vehicles/' || p_id
    when p_entity = 'owner' and exists (select 1 from owners o where o.id = p_id) then v_portal || '/owners/' || p_id
    when p_entity in ('toll', 'toll_ticket') and exists (select 1 from toll_tickets t where t.id = p_id) then case when p_admin then '/admin/tolls/' || p_id else '/staff/tolls' end
    when p_entity = 'field_job' and exists (select 1 from field_jobs j where j.id = p_id) then case when p_admin then '/admin/field-jobs' else '/staff/field/jobs/' || p_id end
    when p_entity = 'job_application' and p_admin and exists (select 1 from job_applications a where a.id = p_id) then '/admin/hiring/' || p_id
    when p_entity = 'bug_report' and exists (select 1 from bug_reports r where r.id = p_id) then case when p_admin then '/admin/bug-reports/' || p_id else '/staff/bug-reports' end
  end;
end $$;

-- ================================================================ 4. the page for this viewer
create or replace function app.alert_path_for(p_user uuid, p_url text, p_code text, p_entity text default null, p_entity_id uuid default null,
                                              p_event_id bigint default null) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_base text := rtrim(coalesce((app.settings()).notify_base_url, ''), '/');
  v_url text := btrim(coalesce(p_url, ''));
  v_host text;
  v_path text;
  v_query text;
  v_hash text;
  v_admin boolean;
  v_field_only boolean;
  v_portal text;
  v_home text;
  v_rule text;
  v_tab text;
  v_num text;
  v_rec text;
begin
  -- renters, owners and investors: as before
  if p_code is null or not exists (select 1 from notification_catalogue c where c.code = p_code and c.audience like 'staff%') then
    return app.push_path(p_url);
  end if;
  -- a link of ours on either host (with or without www.) as a path; anything else is no page
  if v_url ~* '^https?://' then
    v_host := lower(substring(v_url from '^[A-Za-z]+://([^/?#:]+)'));
    if v_base <> '' and regexp_replace(v_host, '^www\.', '') = regexp_replace(lower(coalesce(substring(v_base from '^[A-Za-z]+://([^/?#:]+)'), '')), '^www\.', '') then
      v_url := coalesce(substring(v_url from '^[A-Za-z]+://[^/?#]+(.*)$'), '');
      if v_url !~ '^/' then v_url := '/' || v_url; end if;
    else
      v_url := '/';
    end if;
  elsif v_url !~ '^/[^/\\]' then
    v_url := '/';
  end if;
  v_hash := coalesce(substring(v_url from '(#.*)$'), '');
  v_url := regexp_replace(v_url, '#.*$', '');
  v_query := coalesce(substring(v_url from '(\?.*)$'), '');
  v_path := regexp_replace(regexp_replace(v_url, '\?.*$', ''), '/+$', '');
  if v_path = '' then v_path := '/'; end if;

  v_admin := exists (select 1 from user_roles r where r.user_id = p_user and r.role = 'admin');
  v_field_only := not v_admin
    and not exists (select 1 from staff_profiles sp where sp.user_id = p_user and sp.is_active and sp.staff_type = 'va')
    and exists (select 1 from staff_profiles sp where sp.user_id = p_user and sp.is_active and sp.staff_type = 'field');
  v_portal := case when v_admin then '/admin' else '/staff' end;
  v_home := case when v_field_only then '/staff/field' else v_portal end;
  select e.payload ->> 'rule' into v_rule from app_events e where e.id = p_event_id;

  -- a renter's booking page: the booking in the viewer's portal; other customer pages are no page here
  if v_path ~ '^/account/bookings/[^/]+' then
    v_path := v_portal || '/bookings/' || split_part(v_path, '/', 4); v_query := ''; v_hash := '';
  elsif v_path ~ '^/(account|owner|investor)(/|$)' then
    v_path := '/'; v_query := ''; v_hash := '';
  end if;

  if v_admin then
    -- a staff page: its Admin equal
    if v_path ~ '^/staff/verify/[^/]+$' then
      v_path := '/admin/bookings/' || split_part(v_path, '/', 4); v_query := '?tab=documents';
    elsif v_path = '/staff/fleet' and v_hash = '#tracking' then
      v_path := '/admin/vehicles/tracking'; v_hash := '';
    elsif v_path in ('/staff/fleet', '/staff/cars') then
      v_path := '/admin/vehicles'; v_hash := '';
    elsif v_path ~ '^/staff/field(/|$)' then
      v_path := '/admin/field-jobs'; v_query := ''; v_hash := '';
    elsif v_path = '/staff/tolls' and v_query ~ 'ticket=[0-9a-f-]{36}' then
      v_path := '/admin/tolls/' || substring(v_query from 'ticket=([0-9a-f-]{36})'); v_query := '';
    elsif v_path = '/staff/leads' and v_query ~ 'application=' then
      v_path := '/admin/owners'; v_query := '';
    elsif v_path = '/staff/field-hours' then
      v_path := '/admin/money/field-pay';
    elsif v_path in ('/staff', '/staff/today') then
      v_path := '/admin'; v_query := ''; v_hash := '';
    elsif v_path ~ '^/staff/' then
      v_path := '/admin' || substr(v_path, 7);
    end if;
  else
    -- an Admin page: its staff equal, or the record behind it
    if v_path ~ '^/admin/incidents/[^/]+$' then
      select b.booking_number into v_num from incidents i join bookings b on b.id = i.booking_id where i.incident_number::text = split_part(v_path, '/', 4);
      v_path := case when v_num is not null then '/staff/bookings/' || v_num else '/' end; v_query := case when v_num is not null then '?tab=extras' else '' end;
    elsif v_path ~ '^/admin/disputes/[0-9a-f-]{36}$' then
      select b.booking_number into v_num from disputes d join bookings b on b.id = d.booking_id where d.id = split_part(v_path, '/', 4)::uuid;
      v_path := case when v_num is not null then '/staff/bookings/' || v_num else '/staff/money' end; v_query := case when v_num is not null then '?tab=money' else '' end;
    elsif v_path = '/admin/vehicles/tracking' then
      v_path := '/staff/fleet'; v_query := ''; v_hash := '#tracking';
    elsif v_path in ('/admin/vehicles', '/admin/fleet', '/admin/field-jobs') then
      v_path := '/staff/fleet'; v_query := '';
    elsif v_path in ('/admin/payouts', '/admin/payments', '/admin/debits') then
      v_path := '/staff/money'; v_query := '';
    elsif v_path ~ '^/admin/tolls/[0-9a-f-]{36}$' then
      v_path := '/staff/tolls'; v_query := '';
    elsif v_path in ('/admin', '/admin/overview', '/admin/approvals', '/admin/jobs') then
      v_path := '/staff'; v_query := ''; v_hash := '';
    elsif v_path ~ '^/admin/' then
      v_path := '/staff' || substr(v_path, 7);
    end if;
    -- no page reads a ticket id: the queue (the unmatched ones for an unmatched ticket)
    if v_path = '/staff/tolls' then v_query := case when p_code = 'staff_toll_ticket_unmatched' then '?bucket=unmatched' else '' end; end if;
    if v_field_only and v_path = '/staff' then v_path := '/staff/field'; end if;
  end if;

  -- no page, or only the home page: the record's own page when the notice names one
  if v_path = '/' or v_path = v_portal or v_path = v_home or v_path !~ ('^' || v_portal || '(/|$)') or not app.alert_route_ok(v_path) then
    v_rec := app.alert_record_path(v_admin, p_entity, p_entity_id);
    if v_rec is not null then
      v_path := v_rec; v_query := ''; v_hash := '';
    elsif v_path = '/' or v_path !~ ('^' || v_portal || '(/|$)') or not app.alert_route_ok(v_path) then
      v_path := v_home; v_query := ''; v_hash := '';
    end if;
  end if;

  -- a booking: open the section the alert is about
  if v_path ~ '^/(admin|staff)/bookings/[^/]+$' and v_query !~ '[?&]tab=' then
    v_tab := app.alert_booking_tab(p_code, v_rule);
    if v_tab is not null then v_query := case when v_query = '' then '?tab=' || v_tab else v_query || '&tab=' || v_tab end; end if;
  end if;
  return v_path || v_query || v_hash;
end $$;

revoke all on function app.alert_route_ok(text) from public, anon, authenticated;
revoke all on function app.alert_booking_tab(text, text) from public, anon, authenticated;
revoke all on function app.alert_record_path(boolean, text, uuid) from public, anon, authenticated;
revoke all on function app.alert_path_for(uuid, text, text, text, uuid, bigint) from public, anon, authenticated;
grant execute on function app.alert_route_ok(text) to service_role;
grant execute on function app.alert_booking_tab(text, text) to service_role;
grant execute on function app.alert_record_path(boolean, text, uuid) to service_role;
grant execute on function app.alert_path_for(uuid, text, text, text, uuid, bigint) to service_role;

-- ================================================================ 5. the feed and the phone alert use it
select pg_temp.patch_fn('app.server_alert_feed(uuid, integer, text)'::regprocedure,
  $o$'url', app.push_path(n.url)$o$,
  $n$'url', app.alert_path_for(p_user, n.url, n.code, n.entity, n.entity_id, n.event_id)$n$);
select pg_temp.patch_fn('app.push_from_notice()'::regprocedure,
  $o$app.push_path(new.url)$o$,
  $n$app.alert_path_for(new.user_id, new.url, new.code, new.entity, new.entity_id, new.event_id)$n$);

-- ================================================================ 6. the writers: an alert from the rules with one portal's
-- page only now carries it for the other portal too (alert_path_for maps it), instead of the bare home page
select pg_temp.patch_fn('app.ntf_payload_pre0464(text, app_events, jsonb)'::regprocedure,
  $o$case when p_to ->> 'audience' = 'staff_admin' then p_event.payload ->> 'path_admin' else p_event.payload ->> 'path_staff' end;$o$,
  $n$case when p_to ->> 'audience' = 'staff_admin' then coalesce(p_event.payload ->> 'path_admin', p_event.payload ->> 'path_staff')
                 else coalesce(p_event.payload ->> 'path_staff', p_event.payload ->> 'path_admin') end;$n$);

comment on function app.alert_path_for(uuid, text, text, text, uuid, bigint) is
  'The page a staff alert opens for this viewer (2904): the same page in their portal, the booking section the alert is about, or the record''s own page.';
