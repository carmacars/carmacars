-- 04: row-level security. Each role signs in the way the app does (the "authenticated" database
-- role with the user's id in the JWT) and must NOT be able to read or change what is not theirs.
select test.suite('04 rls');

-- ------------------------------------------------------------------ fixture (dates relative to now)
select test.mk_user('va_fay', 'va', 'finance');
select test.mk_user('va_flo', 'va', 'fleet');
select test.mk_user('va_cora', 'va', 'cs');
select test.mk_user('va_sal', 'va', 'sales');
select test.mk_user('field_gus', 'field', null, 'driver');
update staff_profiles set single_limit_cents = 25000, dual_approval_threshold_cents = 50000 where user_id = test.id('va_fay');

select test.mk_owner('wendy', 'WENDY20');
select test.mk_owner('xavier');
select test.mk_vehicle('W1', 'wendy');
select test.mk_vehicle('W2', 'wendy', 'self_managed', 45000, 2500, 0);
select test.mk_vehicle('X1', 'xavier');
select test.mk_renter('rita'); select test.mk_renter('rob'); select test.mk_renter('tess'); select test.mk_renter('old_oscar', false);

create function pg_temp.ts(p_offset interval) returns text language sql as
$$ select to_char(date_trunc('hour', now() at time zone 'America/Toronto') + p_offset, 'YYYY-MM-DD HH24:MI') $$;

select test.mk_booking('RB1', 'W1', 'rita', pg_temp.ts('-1 day'), pg_temp.ts('2 days'), 'on_rent');            -- managed, on rent now
select test.mk_booking('RB2', 'W2', 'rob', pg_temp.ts('3 days'), pg_temp.ts('5 days'), 'confirmed');           -- self-managed, upcoming
select test.mk_booking('RB3', 'X1', 'rob', pg_temp.ts('-14 days'), pg_temp.ts('-10 days'), 'closed');          -- another owner's car
select test.mk_booking('RB4', 'X1', 'old_oscar', pg_temp.ts('-204 days'), pg_temp.ts('-200 days'), 'closed');  -- an old customer
select test.mk_booking('RB5', 'W1', 'tess', pg_temp.ts('10 days'), pg_temp.ts('12 days'), 'tentative');        -- a quote
select test.mk_booking('RB6', 'X1', 'rob', pg_temp.ts('20 days'), pg_temp.ts('22 days'), 'cancelled', 20000, 'standard', null, pg_temp.ts('-3 days'));
update renters set created_at = now() - interval '300 days' where id = test.id('renter:old_oscar');
select app.compute_booking_split(test.id('booking:RB3'));
insert into booking_line_items (booking_id, charge_type, unit_amount_cents, amount_cents, hst_applies, revenue_class, charged_to_renter, stage)
values (test.id('booking:RB1'), 'referral_kickback', 0, 0, false, 'booking_expense', false, 'split');
insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, licence_number, licence_class, licence_expiry, age_at_pickup, age_band)
values (test.id('booking:RB1'), test.id('driver:rita'), 'renter', 'Rita', date '1990-05-05', 'R1234-56789-01234', 'G', date '2030-01-01', 36, '26_plus');
insert into documents (id, kind, storage_bucket, storage_path, renter_id, booking_id, retention) values
  (test.id('doc:rita:id'), 'id_front', 'identity', 'renters/rita/id_front.jpg', test.id('renter:rita'), test.id('booking:RB1'), 'id_face_90d'),
  (test.id('doc:rita:ra'), 'rental_agreement', 'agreements', 'bookings/RB1/agreement.pdf', test.id('renter:rita'), test.id('booking:RB1'), 'records_7y'),
  (test.id('doc:rob:id'), 'id_front', 'identity', 'renters/rob/id_front.jpg', test.id('renter:rob'), test.id('booking:RB2'), 'id_face_90d'),
  (test.id('doc:oscar:id'), 'id_front', 'identity', 'renters/oscar/id_front.jpg', test.id('renter:old_oscar'), test.id('booking:RB4'), 'id_face_90d');
insert into documents (id, kind, storage_bucket, storage_path, owner_id) values
  (test.id('doc:wendy:ea'), 'enrollment_agreement', 'agreements', 'owners/wendy/enrollment.pdf', test.id('owner:wendy')),
  (test.id('doc:xavier:ea'), 'enrollment_agreement', 'agreements', 'owners/xavier/enrollment.pdf', test.id('owner:xavier'));
insert into documents (id, kind, storage_bucket, storage_path) values (test.id('doc:staff'), 'staff_agreement', 'admin', 'staff/fay.pdf');
insert into identity_verifications (driver_id, booking_id, method, status, id_front_document_id, verified_by, verified_at)
values (test.id('driver:rita'), test.id('booking:RB1'), 'staff_review', 'verified', test.id('doc:rita:id'), test.id('va_cora'), now());
insert into payment_method_secrets (payment_method_id, processor_customer_id, processor_method_id) values (test.id('card:rita'), 'cus_rita', 'pm_rita');
insert into payment_processor_details (payment_id, processor_payment_id) values (test.id('payment:RB1'), 'pi_rb1');
insert into owner_payout_accounts (owner_id, method, account_holder, institution_no, transit_no, account_no, account_last4) values
  (test.id('owner:wendy'), 'bank_transfer', 'Wendy', '002', '00022', '7654321', '4321'),
  (test.id('owner:xavier'), 'bank_transfer', 'Xavier', '003', '00033', '1112223', '2223');
insert into owner_payment_methods (id, owner_id, kind, last4) values (test.id('opm:wendy'), test.id('owner:wendy'), 'pre_authorized_debit', '4321');
insert into owner_payment_method_secrets (owner_payment_method_id, processor_customer_id, processor_mandate_id) values (test.id('opm:wendy'), 'cus_wendy', 'mandate_wendy');
insert into owner_statements (id, owner_id, statement_month, payout_date, status, payout_cents, approved_by) values
  (test.id('st:wendy:1'), test.id('owner:wendy'), date '2026-09-01', date '2026-10-10', 'approved', 50000, test.id('admin_abbas')),
  (test.id('st:wendy:2'), test.id('owner:wendy'), date '2026-10-01', date '2026-11-10', 'draft', 70000, null),
  (test.id('st:xavier:1'), test.id('owner:xavier'), date '2026-09-01', date '2026-10-10', 'approved', 60000, test.id('admin_abbas'));
insert into payouts (id, payee_type, owner_id, kind, owner_statement_id, amount_cents, scheduled_for, status, approved_by) values
  (test.id('po:wendy'), 'owner', test.id('owner:wendy'), 'owner_statement', test.id('st:wendy:1'), 50000, date '2026-10-10', 'approved', test.id('admin_abbas')),
  (test.id('po:xavier'), 'owner', test.id('owner:xavier'), 'owner_statement', test.id('st:xavier:1'), 60000, date '2026-10-10', 'approved', test.id('admin_abbas'));
insert into field_jobs (id, kind, booking_id, vehicle_id, assigned_to, scheduled_at, place) values
  (test.id('job:frank'), 'return_check_in', test.id('booking:RB1'), test.id('vehicle:W1'), test.id('field_frank'), now() + interval '2 hours', '1 Main St'),
  (test.id('job:gus'), 'handover', test.id('booking:RB2'), test.id('vehicle:W2'), test.id('field_gus'), now() + interval '3 hours', '2 King St');
insert into tasks (queue, task_type, title, created_by) values ('finance', 'price_findings', 'Price RB3 findings', test.id('admin_abbas')),
                                                               ('cs', 'verify_renter', 'Verify Rita', test.id('admin_abbas'));
insert into tracker_devices (id, serial_number, vehicle_id, status, installed_at, tested_at) values
  (test.id('trk:W1'), 'TRK-W1', test.id('vehicle:W1'), 'installed', now(), now()),
  (test.id('trk:X1'), 'TRK-X1', test.id('vehicle:X1'), 'installed', now(), now());
insert into tracker_status (tracker_device_id, reported_at, latitude, longitude, speed_kmh, ignition_on) values
  (test.id('trk:W1'), now(), 43.65, -79.38, 0, false), (test.id('trk:X1'), now(), 43.70, -79.40, 0, false);
insert into tracker_access_blocks (vehicle_id, booking_id, starts_at) values (test.id('vehicle:W1'), test.id('booking:RB1'), now() - interval '1 day');
insert into vehicle_listings (vehicle_id, slug, headline, status, published_at) values (test.id('vehicle:W1'), 'c300-w1', 'Mercedes C 300', 'published', now());
insert into users (id, email, full_name) values (test.id('ivy_user'), 'ivy@example.test', 'Ivy Investor');
update investors set user_id = test.id('ivy_user') where id = test.id('inv:ivy');
-- cancellation of RB6 (booked 3 days ago, cancelled now, starts in 20 days: 75%) and two refunds waiting
insert into booking_cancellations (booking_id, received_at, cancelled_by, reason) values (test.id('booking:RB6'), now(), 'renter', 'renter_request');
insert into refunds (id, booking_id, reason, refund_bps, amount_cents, status, requested_by)
select test.id('refund:RB6'), booking_id, 'cancellation', refund_bps, refund_cents, 'pending_approval', test.id('va_fay') from booking_cancellations where booking_id = test.id('booking:RB6');
insert into refunds (id, booking_id, reason, amount_cents, status, requested_by)
values (test.id('refund:goodwill'), test.id('booking:RB3'), 'goodwill', 5000, 'pending_approval', test.id('va_fay'));
insert into deposits (id, booking_id, amount_cents, method, status, captured_cents) values (test.id('dep:RB3'), test.id('booking:RB3'), 100000, 'card_hold', 'captured', 100000);
select test.eq('R5 a refund is due within 10 business days', (select due_by from refunds where id = test.id('refund:RB6')), app.add_business_days(app.today(), 10));
select test.eq('fixture: RB6 refund is 75% of $226.00 = $169.50, inside the finance VA''s $250 Single Limit',
  (select amount_cents from refunds where id = test.id('refund:RB6')), test.money('169.50'));

-- ------------------------------------------------------------------ structure
select test.eq('S every table has row-level security enabled',
  (select string_agg(c.relname, ',') from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity), null::text);
select test.eq('S every table has the admin policy and nothing is granted to the anonymous role by policy',
  (select count(*) filter (where not exists (select 1 from pg_policies p where p.tablename = t.tablename and p.policyname = 'admin_all'))
       || '/' || (select count(*) from pg_policies where schemaname = 'public' and (roles && array['anon', 'public']::name[]))
     from pg_tables t where schemaname = 'public'), '0/0');
select test.eq('S no browser session can delete or truncate from any table',
  (select count(*) from information_schema.role_table_grants
    where table_schema = 'public' and grantee in ('authenticated', 'anon') and privilege_type in ('DELETE', 'TRUNCATE')), 0::bigint);
select test.eq('S the anonymous role can read exactly one thing: the public listings view',
  (select string_agg(table_name || ':' || privilege_type, ',') from information_schema.role_table_grants
    where table_schema = 'public' and grantee = 'anon'), 'public_vehicle_listings:SELECT');
select test.eq('S money-moving functions are not executable from a browser session',
  (select string_agg(p.proname, ',' order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and has_function_privilege('authenticated', p.oid, 'execute')
      and p.proname in ('approve_owner_statement', 'build_owner_statement', 'compute_booking_split', 'generate_owner_invoices',
                        'generate_owner_invoice', 'issue_upfront_invoice', 'settle_claim', 'record_total_loss_settlement',
                        'accrue_investment_return', 'accrue_investment_returns', 'allocate_refund', 'open_claim', 'attach_audit')), null::text);

-- ------------------------------------------------------------------ RENTER
select test.login(test.id('rita'));
select test.eq('renter: sees her own booking through the renter view', test.visible('select * from renter_bookings'), 1::bigint);
select test.eq('renter: and it is hers', (select booking_number from renter_bookings), 'RB1');
select test.eq('renter: the bookings table itself (internal notes, split, referrer) is closed', test.visible('select * from bookings'), 0::bigint);
select test.eq('renter: sees only her own renter record', test.visible('select * from renters'), 1::bigint);
select test.eq('renter: only her own driver record', test.visible('select * from drivers'), 1::bigint);
select test.eq('renter: only her own card (brand and last four)', test.visible('select * from payment_methods'), 1::bigint);
select test.eq('renter: only her own payments', (select string_agg(distinct booking_id::text, ',') from payments), test.id('booking:RB1')::text);
select test.eq('renter: her charge lines, but not the internal kickback line',
  (select string_agg(charge_type, ',' order by charge_type) from booking_line_items), 'rental_charge');
select test.eq('renter: her own documents only (ID image and agreement)', test.visible('select * from documents'), 2::bigint);
select test.eq('renter: cannot see another renter''s ID image', test.visible(format('select * from documents where id = %L', test.id('doc:rob:id'))), 0::bigint);
select test.eq('renter: cannot see another renter''s bookings', test.visible($$select * from renter_bookings where booking_number <> 'RB1'$$), 0::bigint);
select test.eq('renter: no card tokens', test.visible('select * from payment_method_secrets'), 0::bigint);
select test.eq('renter: no processor details', test.visible('select * from payment_processor_details'), 0::bigint);
select test.eq('renter: no owners', test.visible('select * from owners'), 0::bigint);
select test.eq('renter: no vehicle records (VIN, plate, owner)', test.visible('select * from vehicles'), 0::bigint);
select test.eq('renter: no owner statements', test.visible('select * from owner_statements'), 0::bigint);
select test.eq('renter: no payouts', test.visible('select * from payouts'), 0::bigint);
select test.eq('renter: no booking splits', test.visible('select * from booking_splits'), 0::bigint);
select test.eq('renter: no tracker positions', test.visible('select * from tracker_status'), 0::bigint);
select test.eq('renter: no staff tasks', test.visible('select * from tasks'), 0::bigint);
select test.eq('renter: no audit log', test.visible('select * from audit_log'), 0::bigint);
select test.eq('renter: no investors', test.visible('select * from investors'), 0::bigint);
select test.eq('renter: only her own user row', test.visible('select * from users'), 1::bigint);
select test.eq('renter: the owner view shows her nothing', test.visible('select * from owner_bookings'), 0::bigint);
select test.eq('renter: the field view shows her nothing', test.visible('select * from field_job_details'), 0::bigint);
select test.eq('renter: cannot unblock or verify herself (no write to her record)', test.affected($$update renters set is_blocked = false, identity_status = 'verified'$$), 0::bigint);
select test.throws('renter: cannot write a booking directly',
  format($$insert into bookings (booking_number, vehicle_id, renter_id, pickup_at, return_at, original_return_at, billable_days, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, rental_charge_cents, km_allowance_per_day, km_allowance_total, overage_cents_per_km, deposit_cents)
           values ('HACK', %L, %L, now() + interval '40 days', now() + interval '41 days', now() + interval '41 days', 1, 1, 1, 1, 1, 'daily', 1, 0, 0, 0, 0)$$,
         test.id('vehicle:W1'), test.id('renter:rita')), 'row-level security');
select test.throws('renter: cannot delete anything', 'delete from renters', 'permission denied');
select test.throws('renter: cannot run the split', format('select app.compute_booking_split(%L)', test.id('booking:RB1')), 'permission denied');
select test.logout();

select test.login(test.id('rob'));
select test.eq('renter 2: sees his three bookings and not hers',
  (select string_agg(booking_number, ',' order by booking_number) from renter_bookings), 'RB2,RB3,RB6');
select test.eq('renter 2: his own refund request, nobody else''s', test.visible('select * from refunds where booking_id <> ' || quote_literal(test.id('booking:RB6')) || ' and booking_id <> ' || quote_literal(test.id('booking:RB3'))), 0::bigint);
select test.logout();

-- ------------------------------------------------------------------ OWNER
select test.login(test.id('wendy'));
select test.eq('owner: sees her own two vehicles and no one else''s',
  (select string_agg(fleet_number, ',' order by fleet_number) from vehicles), 'F-W1,F-W2');
select test.eq('owner: bookings on her vehicles through the owner view (quotes are not shown)',
  (select string_agg(booking_number, ',' order by booking_number) from owner_bookings), 'RB1,RB2');
select test.eq('owner: on a rental CarmaCars manages, no renter name or phone',
  (select coalesce(renter_name, '-') || '/' || coalesce(renter_mobile, '-') from owner_bookings where booking_number = 'RB1'), '-/-');
select test.eq('owner: on her Self-Managed rental, the name and phone needed to hand over the car',
  (select renter_name || '/' || renter_mobile from owner_bookings where booking_number = 'RB2'), 'Rob/647-555-0199');
select test.eq('owner: the owner view has no email, address, licence or card column',
  (select count(*) from information_schema.columns where table_name = 'owner_bookings'
     and column_name ~ '(email|address|licence|card|birth|renter_id)'), 0::bigint);
select test.eq('owner: the bookings table itself is closed', test.visible('select * from bookings'), 0::bigint);
select test.eq('owner: no renter records', test.visible('select * from renters'), 0::bigint);
select test.eq('owner: no driver or licence records', test.visible('select * from drivers') + test.visible('select * from booking_drivers'), 0::bigint);
select test.eq('owner: no identity checks', test.visible('select * from identity_verifications'), 0::bigint);
select test.eq('owner: no renter cards', test.visible('select * from payment_methods'), 0::bigint);
select test.eq('owner: no renter payments', test.visible('select * from payments'), 0::bigint);
select test.eq('owner: her own agreement, and never the renter''s ID image or rental agreement on her car',
  (select string_agg(kind::text, ',') from documents), 'enrollment_agreement');
select test.eq('owner: her approved statement, not the draft, not another owner''s',
  (select string_agg(statement_month::text || ':' || status, ',') from owner_statements), '2026-09-01:approved');
select test.eq('owner: her own payout only', (select string_agg(amount_cents::text, ',') from payouts), '50000');
select test.eq('owner: her own bank details only', (select string_agg(account_last4, ',') from owner_payout_accounts), '4321');
select test.eq('owner: no debit mandate tokens', test.visible('select * from owner_payment_method_secrets'), 0::bigint);
select test.eq('owner: another owner''s vehicle, statement and booking are invisible',
  test.visible(format('select 1 from vehicles where id = %L', test.id('vehicle:X1')))
  + test.visible(format('select 1 from owner_statements where id = %L', test.id('st:xavier:1')))
  + test.visible($$select 1 from owner_bookings where booking_number = 'RB3'$$)
  + test.visible('select 1 from booking_splits'), 0::bigint);
select test.eq('owner: keeps live location of her own vehicle, also during a rental', test.visible('select * from tracker_status'), 1::bigint);
insert into tracker_commands (tracker_device_id, vehicle_id, command, actor_type, requested_by, reason_code, reason)
values (test.id('trk:W1'), test.id('vehicle:W1'), 'lock', 'owner', test.id('wendy'), 'owner_protecting_vehicle', 'checking the doors');
select test.eq('owner: her lock command during a managed rental is refused and logged as blocked',
  (select status from tracker_commands where requested_by = test.id('wendy')), 'blocked');
select test.throws('owner: cannot command another owner''s vehicle',
  format($$insert into tracker_commands (tracker_device_id, vehicle_id, command, actor_type, requested_by, reason_code, reason)
           values (%L, %L, 'lock', 'owner', %L, 'owner_protecting_vehicle', 'x')$$, test.id('trk:X1'), test.id('vehicle:X1'), test.id('wendy')), 'row-level security');
select test.eq('owner: cannot change her vehicle''s terms or status', test.affected('update vehicles set in_arrears = false, bookings_enabled = true'), 0::bigint);
select test.eq('owner: claims table closed; claim money is not on her account', test.visible('select * from claims') + test.visible('select * from claim_ledger_entries'), 0::bigint);
select test.eq('owner: no investors, audit log, tasks or other users',
  test.visible('select * from investors') + test.visible('select * from audit_log') + test.visible('select * from tasks') + test.visible('select * from users where id <> app.uid()'), 0::bigint);
select test.logout();

select test.login(test.id('otto'));
select test.eq('owner (referrer): sees the kickbacks he earned and no one else''s',
  (select bool_and(referrer_owner_id = test.id('owner:otto')) || '/' || (count(*) > 0) from referral_kickbacks), 'true/true');
select test.logout();

-- ------------------------------------------------------------------ VA: finance and billing
select test.login(test.id('va_fay'));
select test.eq('finance: no full card data (tokens)', test.visible('select * from payment_method_secrets'), 0::bigint);
select test.eq('finance: no processor payloads', test.visible('select * from payment_processor_details'), 0::bigint);
select test.eq('finance: no owner bank account numbers', test.visible('select * from owner_payout_accounts'), 0::bigint);
select test.eq('finance: no debit mandate tokens', test.visible('select * from owner_payment_method_secrets'), 0::bigint);
select test.eq('finance: sees payments (amount, status, last four)', test.visible('select * from payments') > 0, true);
select test.eq('finance: prepares owner statements', test.visible('select * from owner_statements') > 0, true);
select test.eq('finance: no investors, investments or investor payouts',
  test.visible('select * from investors') + test.visible('select * from investments') + test.visible($$select * from payouts where payee_type = 'investor'$$), 0::bigint);
select test.eq('finance: no investor or staff documents, no ID images',
  test.visible($$select * from documents where kind::text like 'invest%' or kind in ('staff_agreement', 'id_front', 'id_back', 'face_photo')$$), 0::bigint);
select test.eq('finance: no licence records', test.visible('select * from drivers'), 0::bigint);
select test.eq('finance: no user list (emails for export)', test.visible('select * from users'), 1::bigint);
select test.eq('finance: no audit log', test.visible('select * from audit_log'), 0::bigint);
select test.eq('finance: no tracker commands', test.visible('select * from tracker_commands'), 0::bigint);
select test.eq('finance: a customer whose last rental ended 200 days ago is not in reach',
  test.visible(format('select * from renters where id = %L', test.id('renter:old_oscar'))), 0::bigint);
select test.eq('finance: current customers are', test.visible(format('select * from renters where id in (%L, %L)', test.id('renter:rita'), test.id('renter:rob'))), 2::bigint);
select test.eq('finance: sees the finance queue, not the CS queue', (select string_agg(queue, ',') from tasks), 'finance');
select test.throws('finance: cannot approve a refund outside the cancellation table',
  format($$update refunds set status = 'approved', approved_by = %L where id = %L$$, test.id('va_fay'), test.id('refund:goodwill')), 'needs an Admin');
select test.throws('finance: cannot record an Admin''s approval for them',
  format($$update refunds set status = 'approved', approved_by = %L where id = %L$$, test.id('admin_abbas'), test.id('refund:goodwill')), 'your own approval');
select test.lives('finance: may release a table refund inside the Single Limit ($169.50 of $250)',
  format($$update refunds set status = 'approved', approved_by = %L where id = %L$$, test.id('va_fay'), test.id('refund:RB6')));
select test.throws('finance: cannot release a deposit above the Single Limit ($1,000)',
  format($$update deposits set released_cents = 100000, release_approved_by = %L where id = %L$$, test.id('va_fay'), test.id('dep:RB3')), 'needs an Admin');
select test.lives('finance: prepares a payout',
  format($$insert into payouts (id, payee_type, owner_id, kind, amount_cents, scheduled_for, status, prepared_by)
           values (%L, 'owner', %L, 'other', 1000, current_date, 'pending_approval', %L)$$, test.id('po:draft'), test.id('owner:wendy'), test.id('va_fay')));
select test.throws('finance: cannot approve a payout',
  format($$update payouts set status = 'approved', approved_by = %L where id = %L$$, test.id('va_fay'), test.id('po:draft')), null);
select test.eq('finance: cannot alter an approved payout', test.affected(format('update payouts set amount_cents = 999999 where id = %L', test.id('po:wendy'))), 0::bigint);
select test.throws('finance: cannot set a vehicle''s Fees or Revenue Share',
  format($$insert into vehicle_fee_history (vehicle_id, source, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, effective_from)
           values (%L, 'correction', 0, 0, 0, date '2030-01-01')$$, test.id('vehicle:W1')), 'row-level security');
select test.throws('finance: cannot change a payee''s bank details',
  format($$insert into owner_payout_accounts (owner_id, method, account_holder, is_current) values (%L, 'e_transfer', 'Fay', false)$$, test.id('owner:wendy')), 'row-level security');
select test.throws('finance: cannot delete records', 'delete from booking_line_items', 'permission denied');
select test.throws('finance: cannot run a payout approval function', format('select app.approve_owner_statement(%L, %L)', test.id('st:wendy:2'), test.id('va_fay')), 'permission denied');
select test.eq('finance: cannot raise their own limit', test.affected('update staff_profiles set single_limit_cents = 99999999'), 0::bigint);
select test.eq('finance: their limit is unchanged', (select single_limit_cents from staff_profiles), 25000::bigint);
-- an older customer: one logged search, one logged, time-limited open
select test.eq('finance: the search returns a name and a booking number, at most 10 rows', (select count(*) from app.staff_find_renter('Old Oscar')), 1::bigint);
select app.staff_open_renter(test.id('renter:old_oscar'), 'chargeback evidence for RB4');
select test.eq('finance: after a logged open with a reason, that one record is in reach for 24 hours',
  test.visible(format('select * from renters where id = %L', test.id('renter:old_oscar'))), 1::bigint);
select test.throws('finance: an open without a reason is refused', format('select app.staff_open_renter(%L, '''')', test.id('renter:old_oscar')), 'reason');
select test.logout();
select test.eq('log: the search and the open are on the access log',
  (select string_agg(action, ',' order by id) from data_access_log where user_id = test.id('va_fay')), 'search,open');
select test.throws('guard: even outside RLS, a VA can never be the approver of a payout',
  format($$update payouts set status = 'approved', approved_by = %L where id = %L$$, test.id('va_fay'), test.id('po:draft')), 'Only an Admin approves a payout');
select test.throws('guard: a table refund above the Single Limit needs an Admin',
  format($$update staff_profiles set single_limit_cents = 10000 where user_id = %L;
           update refunds set status = 'pending_approval', approved_by = null where id = %L;
           update refunds set status = 'approved', approved_by = %L where id = %L$$,
         test.id('va_fay'), test.id('refund:RB6'), test.id('va_fay'), test.id('refund:RB6')), 'needs an Admin');

-- ------------------------------------------------------------------ VA: fleet operations
select test.login(test.id('va_flo'));
select test.eq('fleet: no payments, refunds, deposits or disputes',
  test.visible('select * from payments') + test.visible('select * from refunds') + test.visible('select * from deposits') + test.visible('select * from disputes'), 0::bigint);
select test.eq('fleet: no owner invoices, statements or payouts',
  test.visible('select * from owner_invoices') + test.visible('select * from owner_statements') + test.visible('select * from payouts'), 0::bigint);
select test.eq('fleet: no ID images, no cards, no bank details',
  test.visible($$select * from documents where kind in ('id_front', 'id_back', 'face_photo')$$) + test.visible('select * from payment_methods')
  + test.visible('select * from owner_payout_accounts') + test.visible('select * from payment_method_secrets'), 0::bigint);
select test.eq('fleet: sees the fleet and the bookings calendar', test.visible('select * from vehicles') > 0 and test.visible('select * from bookings') > 0, true);
select test.lives('fleet: may request a tracker command, with who and why',
  format($$insert into tracker_commands (id, tracker_device_id, vehicle_id, booking_id, command, actor_type, requested_by, reason_code, reason)
           values (%L, %L, %L, %L, 'engine_disable', 'staff', %L, 'late_return', '2 hours overdue, T14 sent')$$,
         test.id('cmd:flo'), test.id('trk:W1'), test.id('vehicle:W1'), test.id('booking:RB1'), test.id('va_flo')));
select test.throws('fleet: cannot log a command in someone else''s name',
  format($$insert into tracker_commands (tracker_device_id, vehicle_id, command, actor_type, requested_by, reason_code, reason)
           values (%L, %L, 'locate', 'staff', %L, 'late_return', 'x')$$, test.id('trk:W1'), test.id('vehicle:W1'), test.id('admin_abbas')), 'row-level security');
select test.throws('fleet: cannot approve a disable themselves',
  format($$update tracker_commands set status = 'approved', approved_by = %L where id = %L$$, test.id('va_flo'), test.id('cmd:flo')), 'Only an Admin');
select test.throws('fleet: cannot record an Admin''s approval for them',
  format($$update tracker_commands set status = 'approved', approved_by = %L where id = %L$$, test.id('admin_abbas'), test.id('cmd:flo')), 'your own approval');
select test.throws('fleet: cannot send a disable without approval',
  format($$update tracker_commands set status = 'sent', sent_at = now(), observed_at = now(), observed_speed_kmh = 0, observed_ignition_on = false where id = %L$$, test.id('cmd:flo')), null);
select test.throws('fleet: cannot change who owns a vehicle or how it is managed',
  format($$update vehicles set management_mode = 'self_managed' where id = %L$$, test.id('vehicle:W1')), 'Only an Admin changes management_mode');
select test.eq('fleet: sees the fleet queue only', test.visible($$select * from tasks where queue <> 'fleet'$$), 0::bigint);
select test.logout();

-- ------------------------------------------------------------------ VA: customer service and growth
select test.login(test.id('va_cora'));
select test.eq('cs: verifies identity, so sees the ID image of a renter with a live booking',
  test.visible(format('select * from documents where id = %L', test.id('doc:rita:id'))), 1::bigint);
select test.eq('cs: but not the ID image of a customer from 200 days ago',
  test.visible(format('select * from documents where id = %L', test.id('doc:oscar:id'))), 0::bigint);
select test.eq('cs: nor that customer''s record or licence',
  test.visible(format('select * from renters where id = %L', test.id('renter:old_oscar')))
  + test.visible(format('select * from drivers where renter_id = %L', test.id('renter:old_oscar'))), 0::bigint);
select test.eq('cs: no owner statements, payouts, splits, claims or bank details',
  test.visible('select * from owner_statements') + test.visible('select * from payouts') + test.visible('select * from booking_splits')
  + test.visible('select * from claims') + test.visible('select * from owner_payout_accounts'), 0::bigint);
select test.eq('cs: no card tokens, no investors, no staff documents',
  test.visible('select * from payment_method_secrets') + test.visible('select * from investors')
  + test.visible($$select * from documents where kind = 'staff_agreement'$$), 0::bigint);
select test.eq('cs: no tracker positions or commands', test.visible('select * from tracker_status') + test.visible('select * from tracker_commands'), 0::bigint);
select test.eq('cs: can see that a booking is paid', test.visible('select * from payments') > 0, true);
select test.throws('cs: cannot write a payment',
  format($$insert into payments (booking_id, purpose, kind, amount_cents, status) values (%L, 'other', 'charge', 100, 'succeeded')$$, test.id('booking:RB1')), 'row-level security');
select test.throws('cs: cannot write a refund', format($$insert into refunds (booking_id, reason, amount_cents) values (%L, 'goodwill', 100)$$, test.id('booking:RB1')), 'row-level security');
select test.throws('cs: cannot change a booking''s split',
  format('update bookings set company_share_bps = 0 where id = %L', test.id('booking:RB5')), 'Only an Admin changes company_share_bps');
select test.throws('cs: cannot make an owner a shareholder or touch a balance',
  format('update owners set is_shareholder = true where id = %L', test.id('owner:wendy')), 'Only an Admin changes is_shareholder');
select test.lives('cs: may log a renter''s message', format($$insert into messages (direction, channel, body, renter_id, sent_by) values ('outbound', 'email', 'hello', %L, %L)$$, test.id('renter:rita'), test.id('va_cora')));
select test.logout();

-- ------------------------------------------------------------------ VA: sales (optional role)
select test.login(test.id('va_sal'));
select test.eq('sales: sees quotes only', test.visible($$select * from bookings where status not in ('tentative', 'pending_payment')$$), 0::bigint);
select test.eq('sales: and there are quotes to see', test.visible($$select * from bookings where status = 'tentative'$$) > 0, true);
select test.eq('sales: no payments, licences, documents, owners, statements or payouts',
  test.visible('select * from payments') + test.visible('select * from drivers') + test.visible('select * from documents')
  + test.visible('select * from owners') + test.visible('select * from owner_statements') + test.visible('select * from payouts'), 0::bigint);
select test.eq('sales: no owner terms (fees, Revenue Share), no tracker positions',
  test.visible('select * from vehicle_schedules') + test.visible('select * from vehicle_fee_history') + test.visible('select * from tracker_status'), 0::bigint);
select test.eq('sales: can see the rates to quote from', test.visible('select * from rate_cards') > 0, true);
select test.eq('sales: cannot confirm a booking', test.affected(format($$update bookings set notes = 'x' where id = %L$$, test.id('booking:RB2'))), 0::bigint);
select test.logout();

-- ------------------------------------------------------------------ FIELD STAFF
select test.login(test.id('field_frank'));
select test.eq('field: sees only the job assigned to him', (select string_agg(kind, ',') from field_jobs), 'return_check_in');
select test.eq('field: the job view gives who to meet, the card to match and the licence to check',
  (select booking_number || '/' || renter_name || '/' || card_last4 || '/' || (drivers -> 0 ->> 'licence_number') from field_job_details), 'RB1/Rita/4242/R1234-56789-01234');
select test.eq('field: another driver''s job is invisible', test.visible(format('select * from field_jobs where id = %L', test.id('job:gus'))), 0::bigint);
select test.eq('field: no booking table, renters, licences table, payments or documents',
  test.visible('select * from bookings') + test.visible('select * from renters') + test.visible('select * from drivers')
  + test.visible('select * from booking_drivers') + test.visible('select * from payments') + test.visible('select * from documents'), 0::bigint);
select test.eq('field: only the vehicle of his job', (select string_agg(fleet_number, ',') from vehicles), 'F-W1');
select test.eq('field: no owners, statements, payouts of others, tasks or audit log',
  test.visible('select * from owners') + test.visible('select * from owner_statements') + test.visible('select * from payouts')
  + test.visible('select * from tasks') + test.visible('select * from audit_log'), 0::bigint);
select test.eq('field: sees his own referral kickbacks only',
  (select bool_and(referrer_staff_id = test.id('field_frank')) || '/' || count(*) from referral_kickbacks), 'true/1');
select test.eq('field: may acknowledge his job', test.affected($$update field_jobs set status = 'acknowledged', acknowledged_at = now()$$), 1::bigint);
select test.throws('field: cannot reassign or redirect his job', format('update field_jobs set assigned_to = %L', test.id('field_gus')), 'only update the progress');
select test.lives('field: files the Condition Report for his job',
  format($$insert into condition_reports (id, vehicle_id, booking_id, field_job_id, kind, performed_by, odometer_km, fuel_pct)
           values (%L, %L, %L, %L, 'return', %L, 30500, 90)$$, test.id('cr:RB1:in'), test.id('vehicle:W1'), test.id('booking:RB1'), test.id('job:frank'), test.id('field_frank')));
select test.lives('field: and its photos',
  format($$insert into condition_report_photos (condition_report_id, seq, shot, storage_path, uploaded_by) values (%L, 1, 'front', 'bookings/RB1/return/front.jpg', %L)$$, test.id('cr:RB1:in'), test.id('field_frank')));
select test.throws('field: cannot file a report on a booking that is not his job',
  format($$insert into condition_reports (vehicle_id, booking_id, kind, performed_by) values (%L, %L, 'pickup', %L)$$, test.id('vehicle:W2'), test.id('booking:RB2'), test.id('field_frank')), 'row-level security');
select test.eq('field: cannot check a car in himself (the status belongs to Fleet)',
  test.affected(format($$update bookings set status = 'returned' where id = %L$$, test.id('booking:RB1'))), 0::bigint);
select test.logout();
select test.eq('field: the booking is still on rent', (select status::text from bookings where id = test.id('booking:RB1')), 'on_rent');

-- ------------------------------------------------------------------ INVESTOR
select test.login(test.id('ivy_user'));
select test.eq('investor: sees her own investment and not the other investor''s',
  (select string_agg(legal_name, ',') from investors) || '/' || test.visible('select * from investments'), 'Ivy Investor/1');
select test.eq('investor: her own Returns', test.visible('select * from investment_returns') > 0, true);
select test.eq('investor: her own payout only', (select string_agg(kind, ',') from payouts), 'investor_return');
select test.eq('investor: nothing of the rental business',
  test.visible('select * from bookings') + test.visible('select * from owners') + test.visible('select * from vehicles')
  + test.visible('select * from renters') + test.visible('select * from owner_statements'), 0::bigint);
select test.logout();

-- ------------------------------------------------------------------ ANONYMOUS (the public site)
set role anon;
select test.eq('anon: can read the published listing', test.visible('select * from public_vehicle_listings'), 1::bigint);
select test.eq('anon: the listing carries no VIN, plate or owner',
  (select count(*) from information_schema.columns where table_name = 'public_vehicle_listings' and column_name in ('vin', 'plate', 'owner_id', 'fleet_number')), 0::bigint);
select test.eq('anon: no privilege at all on vehicles, renters, bookings or users',
  test.visible('select * from vehicles') + test.visible('select * from renters') + test.visible('select * from bookings') + test.visible('select * from users'), -4::bigint);
reset role;

-- ------------------------------------------------------------------ ADMIN
select test.login(test.id('admin_abbas'));
select test.eq('admin: sees everything, including what every other role cannot',
  test.visible('select * from payment_method_secrets') > 0 and test.visible('select * from owner_payout_accounts') >= 2
  and test.visible('select * from investors') = 2 and test.visible('select * from audit_log') > 0
  and test.visible(format('select * from renters where id = %L', test.id('renter:old_oscar'))) = 1
  and test.visible($$select * from owner_statements where status = 'draft'$$) > 0
  and test.visible('select * from data_access_log') = 2, true);
select test.lives('admin: approves the refund the VA could not',
  format($$update refunds set status = 'approved', approved_by = %L where id = %L$$, test.id('admin_abbas'), test.id('refund:goodwill')));
select test.lives('admin: approves the payout the VA prepared',
  format($$update payouts set status = 'approved', approved_by = %L where id = %L$$, test.id('admin_abbas'), test.id('po:draft')));
select test.throws('admin: but cannot record the other admin''s approval', 
  format($$update payouts set second_approved_by = %L where id = %L$$, test.id('admin_mahad'), test.id('po:draft')), null);
select test.throws('admin: still cannot delete from a browser session (records are kept)', 'delete from bookings', 'permission denied');
select test.logout();

-- ------------------------------------------------------------------ access ends with the account
update users set status = 'suspended' where id = test.id('va_cora');
select test.login(test.id('va_cora'));
select test.eq('a suspended VA sees nothing', test.visible('select * from bookings') + test.visible('select * from renters') + test.visible('select * from owners') + test.visible('select * from documents'), 0::bigint);
select test.logout();
update staff_profiles set is_active = false where user_id = test.id('field_frank');
select test.login(test.id('field_frank'));
select test.eq('a field worker whose profile is ended sees no jobs', test.visible('select * from field_jobs') + test.visible('select * from field_job_details'), 0::bigint);
select test.logout();
