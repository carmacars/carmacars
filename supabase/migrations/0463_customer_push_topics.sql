-- 0463: every time-sensitive notice to a renter or owner that had no phone-alert topic gets one (docs/alerts/matrix.md),
-- so the browser and the native app (same outbox and topics, 0300) alert them. Renters keep every topic on by default, owners
-- requests, bookings, payments, alerts and documents (app.push_default_topics); each person switches topics per device on
-- their Account alerts card. Marketing, sign-in links and codes, comeback and promo reminders get none (CASL).
-- SCHEMA_MARKER 0463. No applied migration is edited.
update notification_catalogue c set push_topic = t.topic
  from (values
    ('renter_rental_started', 'handovers'), ('renter_extension_requested', 'requests'), ('renter_change_request_received', 'requests'),
    ('renter_request_received', 'requests'), ('renter_agreement_signed', 'documents'), ('renter_agreement_version', 'documents'),
    ('renter_driver_link', 'documents'), ('renter_review_ask', 'messages'), ('renter_review_request', 'messages'),
    ('renter_review_reminder', 'messages'), ('renter_review_final', 'messages'),
    ('owner_application_received', 'requests'), ('owner_application_approved', 'requests'), ('owner_application_declined', 'requests'),
    ('owner_application_info_requested', 'requests'), ('owner_onboarding_steps', 'requests'), ('owner_agreement_signed', 'documents'),
    ('owner_form_approved', 'documents'), ('owner_form_rejected', 'documents'), ('owner_bank_details_changed', 'alerts'),
    ('owner_toll_ticket', 'alerts'), ('owner_exit_notice_received', 'alerts'), ('owner_exit_completed', 'alerts'),
    ('owner_debit_notice', 'payments'), ('owner_debit_setup_needed', 'payments'), ('owner_in_arrears', 'payments'),
    ('owner_payment_recorded', 'payments'), ('owner_fee_invoice', 'payments'), ('owner_upfront_invoice', 'payments'), ('owner_invoice_voided', 'payments'),
    ('owner_vehicle_listed', 'bookings'), ('owner_vehicle_enrolled', 'bookings'), ('owner_car_set_up', 'bookings'),
    ('owner_fee_change_notice', 'bookings'), ('owner_mode_change_notice', 'bookings')
  ) as t(code, topic)
 where c.code = t.code and c.push_topic is null and c.category <> 'marketing';

-- ================================================================ the app download prompt
-- Once the native app is in the stores, phones are asked to download it instead of turning on browser alerts (and on an
-- iPhone, instead of the Add to Home Screen steps). Empty until published; desktop keeps browser alerts.
alter table program_settings
  add column if not exists app_store_url text check (app_store_url is null or app_store_url = '' or app_store_url ~ '^https://[^[:space:]]+$'),
  add column if not exists play_store_url text check (play_store_url is null or play_store_url = '' or play_store_url ~ '^https://[^[:space:]]+$');
comment on column program_settings.app_store_url is 'Native app (0463): the App Store link. When set, iPhones and iPads see "Download the CarmaCars app" instead of the Add to Home Screen steps. Empty until published.';
comment on column program_settings.play_store_url is 'Native app (0463): the Google Play link. When set, Android phones see "Download the CarmaCars app" instead of browser alerts. Empty until published.';

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;
alter function app.push_state(uuid, text) rename to push_state_pre0463;
create function app.push_state(p_user uuid, p_endpoint text default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.push_state_pre0463(p_user, p_endpoint);
  s program_settings := app.settings();
begin
  return v || jsonb_build_object('store', jsonb_build_object('ios', nullif(s.app_store_url, ''), 'android', nullif(s.play_store_url, '')));
end $$;
select pg_temp.copy_grants('app.push_state(uuid, text)'::regprocedure, 'app.push_state_pre0463(uuid, text)'::regprocedure);
revoke all on function app.push_state_pre0463(uuid, text) from public, anon, authenticated;
grant execute on function app.push_state_pre0463(uuid, text) to service_role;
