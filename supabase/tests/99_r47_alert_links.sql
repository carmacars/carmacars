-- 99_r47_alert_links: an alert opens the right page for the person who clicks it (2904). Fixtures start with "al47".
select test.suite('99 r47 alert links');

select test.mk_user('al47_admin', 'admin');
select test.mk_user('al47_cs', 'va', 'cs');
select test.mk_user('al47_fin', 'va', 'finance');
select test.mk_user('al47_fleet', 'va', 'fleet');
select test.mk_user('al47_field', 'field');
select test.mk_owner('al47_own');
select test.mk_vehicle('AL47V', 'al47_own');
select test.mk_renter('al47_ren');
select test.mk_booking('AL4701', 'AL47V', 'al47_ren', '2026-12-01 10:00', '2026-12-05 10:00', 'confirmed');

create temp table al47 as select (app.settings()).notify_base_url b, test.id('booking:AL4701') bk, test.id('al47:ticket') tk, test.id('al47:dispute') dp;
create function pg_temp.at(p_who text, p_url text, p_code text, p_entity text default null, p_id uuid default null, p_event bigint default null) returns text
language sql as $$ select app.alert_path_for(test.id(p_who), p_url, p_code, p_entity, p_id, p_event) $$;

-- staff booking pages to an Admin, with the section the alert is about
select test.eq('late return: Admin gets the Admin booking, Car section',
  pg_temp.at('al47_admin', (select b from al47) || '/staff/bookings/AL4701', 'staff_late_return_alert'), '/admin/bookings/AL4701?tab=car');
select test.eq('late return: Fleet gets the staff booking, Car section',
  pg_temp.at('al47_fleet', (select b from al47) || '/staff/bookings/AL4701', 'staff_late_return_alert'), '/staff/bookings/AL4701?tab=car');
select test.eq('change request: Customer service opens Claims & extras',
  pg_temp.at('al47_cs', (select b from al47) || '/staff/bookings/AL4701', 'staff_change_request_received'), '/staff/bookings/AL4701?tab=extras');
select test.eq('identity review: Admin opens the booking documents',
  pg_temp.at('al47_admin', (select b from al47) || '/staff/verify/AL4701', 'staff_identity_review'), '/admin/bookings/AL4701?tab=documents');
select test.eq('identity review: Customer service keeps the verify page',
  pg_temp.at('al47_cs', (select b from al47) || '/staff/verify/AL4701', 'staff_identity_review'), '/staff/verify/AL4701');
select test.eq('a tab already chosen is kept',
  pg_temp.at('al47_admin', '/admin/bookings/AL4701?tab=documents', 'staff_payment_failed'), '/admin/bookings/AL4701?tab=documents');

-- the other host (www.) is still our site; another site is no page
select test.eq('www. link: Admin gets the booking, Money section',
  pg_temp.at('al47_admin', replace((select b from al47), '://', '://www.') || '/staff/bookings/AL4701', 'staff_payment_failed'), '/admin/bookings/AL4701?tab=money');
select test.eq('www. link: Finance gets the staff booking, Money section',
  pg_temp.at('al47_fin', replace((select b from al47), '://', '://www.') || '/staff/bookings/AL4701', 'staff_payment_failed'), '/staff/bookings/AL4701?tab=money');
select test.eq('another site: the Admin home',
  pg_temp.at('al47_admin', 'https://elsewhere.example/staff/bookings/AL4701', 'staff_payment_failed'), '/admin');

-- Admin pages to staff
select test.eq('dispute: Admin keeps the dispute page',
  pg_temp.at('al47_admin', (select b from al47) || '/admin/disputes/' || (select dp from al47), 'staff_dispute_opened'), '/admin/disputes/' || (select dp from al47));
select test.eq('dispute: Finance gets Money (no dispute page in their portal)',
  pg_temp.at('al47_fin', (select b from al47) || '/admin/disputes/' || (select dp from al47), 'staff_dispute_opened'), '/staff/money');
select test.eq('incident: Fleet gets the booking claims from the notice''s booking',
  pg_temp.at('al47_fleet', (select b from al47) || '/admin/incidents/987654', 'staff_incident_reported', 'booking', (select bk from al47)), '/staff/bookings/AL4701?tab=extras');
select test.eq('incident: Admin keeps the incident page',
  pg_temp.at('al47_admin', (select b from al47) || '/admin/incidents/987654', 'staff_incident_reported', 'booking', (select bk from al47)), '/admin/incidents/987654');
select test.eq('payouts due: Finance gets Money',
  pg_temp.at('al47_fin', (select b from al47) || '/admin/payouts', 'staff_payouts_due'), '/staff/money');
select test.eq('tracker: Fleet gets the fleet tracking view',
  pg_temp.at('al47_fleet', (select b from al47) || '/admin/vehicles/tracking', 'staff_tracker_alert'), '/staff/fleet#tracking');
select test.eq('tracker (fleet copy): Admin gets the tracking page',
  pg_temp.at('al47_admin', (select b from al47) || '/staff/fleet#tracking', 'staff_tracker_alert_fleet'), '/admin/vehicles/tracking');
select test.eq('expiry watch: Admin gets the cars list',
  pg_temp.at('al47_admin', (select b from al47) || '/staff/fleet#expiry', 'staff_expiry_watch'), '/admin/vehicles');

-- ids no page reads
select test.eq('unmatched toll: Admin opens the ticket',
  pg_temp.at('al47_admin', (select b from al47) || '/staff/tolls?ticket=' || (select tk from al47), 'staff_toll_ticket_unmatched'), '/admin/tolls/' || (select tk from al47));
select test.eq('unmatched toll: Finance opens the unmatched queue',
  pg_temp.at('al47_fin', (select b from al47) || '/staff/tolls?ticket=' || (select tk from al47), 'staff_toll_ticket_unmatched'), '/staff/tolls?bucket=unmatched');

-- no page: the record's own page; renter pages are the booking
select test.eq('"/" with a booking: the booking',
  pg_temp.at('al47_cs', '/', 'staff_alert_normal', 'booking', (select bk from al47)), '/staff/bookings/AL4701');
select test.eq('home with a booking: the booking',
  pg_temp.at('al47_admin', (select b from al47) || '/admin', 'staff_alert_normal', 'booking', (select bk from al47)), '/admin/bookings/AL4701');
select test.eq('a renter page: the booking in the staff portal, Messages',
  pg_temp.at('al47_cs', (select b from al47) || '/account/bookings/AL4701', 'staff_renter_replied'), '/staff/bookings/AL4701?tab=activity');
select test.eq('a page the portal does not have, no record: the home',
  pg_temp.at('al47_cs', '/admin/settings/usage', 'staff_usage_alert'), '/staff');
select test.eq('digest stays on the home page',
  pg_temp.at('al47_admin', (select b from al47) || '/admin', 'staff_digest_morning_admin'), '/admin');

-- field work
select test.eq('field job change: field staff keep their jobs',
  pg_temp.at('al47_field', (select b from al47) || '/staff/field', 'staff_field_job_changed'), '/staff/field');
select test.eq('field job change: Admin gets the field jobs board',
  pg_temp.at('al47_admin', (select b from al47) || '/staff/field/jobs/' || (select tk from al47), 'staff_field_job_assigned'), '/admin/field-jobs');

-- customers' notices are unchanged
select test.eq('a renter notice: as app.push_path',
  pg_temp.at('al47_admin', (select b from al47) || '/account/bookings/AL4701', (select min(code) from notification_catalogue where audience = 'renter')), '/account/bookings/AL4701');

-- an alert from the rules with only the Admin page: staff now get that page in their portal, with the section of the rule
do $$
declare v_e bigint; e app_events; v_url text;
begin
  v_e := app.staff_alert('card_declined_pickup', 'booking', test.id('booking:AL4701'), 'al47', 'Card declined', 'AL4701', jsonb_build_object('path_admin', '/admin/bookings/AL4701'));
  select * into e from app_events where id = v_e;
  v_url := app.ntf_payload_pre0464('staff_alert_urgent', e, '{"audience": "staff_va_fleet"}'::jsonb) ->> '_url';
  perform test.eq('rule alert: the staff recipient''s link is the page, not the home', v_url, (select b from al47) || '/admin/bookings/AL4701');
  perform test.eq('rule alert: Fleet opens the staff booking, Money section',
    app.alert_path_for(test.id('al47_fleet'), v_url, 'staff_alert_urgent', 'booking', test.id('booking:AL4701'), v_e), '/staff/bookings/AL4701?tab=money');
end $$;

-- the feed and the phone alert use it
insert into notifications (user_id, code, title, url, dedupe_key)
  values (test.id('al47_admin'), 'staff_late_return_alert', 'Late', (select b from al47) || '/staff/bookings/AL4701', 'al47:feed');
select test.eq('feed: the Admin''s alert opens the Admin booking',
  (select x ->> 'url' from jsonb_array_elements(app.server_alert_feed(test.id('al47_admin'))) x where x ->> 'code' = 'staff_late_return_alert' limit 1), '/admin/bookings/AL4701?tab=car');
select test.ok('the phone alert uses the viewer''s page',
  pg_get_functiondef('app.push_from_notice()'::regprocedure) like '%app.alert_path_for(new.user_id, new.url%'
  and pg_get_functiondef('app.push_from_notice()'::regprocedure) not like '%app.push_path(new.url)%');
