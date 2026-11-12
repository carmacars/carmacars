-- 99: Release 23 (migrations 0220 to 0240, docs/changes/2026-11-03-*.md). IndexNow's changed pages on their own back-off
-- and first, the sweep inside the crawl scope; the CPU guard flag; usage alerts texted to the Admins; Cloudflare email
-- first; the hiring decisions sent together; remote calls confirmed or cancelled, the call method by role; the Quo texts
-- on Usage; the search scope; a credit card by default with an Admin's override per booking. Release 23b: every class in the class pickers; insurers' adjusters and
-- the billing by class, car and adjuster; tasks that close themselves; the cars on sample photos; a car's registration,
-- documents and move; owner charges deducted from payouts; the Tracker Fee from the installation. Fixtures start with "r23".
select test.suite('99 release 23');
-- 1060 (part K) turned on by default: Sales referral of every VA applicant, AI interviews for every role, auto-hire; this suite tests the rules before them
update program_settings set hiring_refer_va_to_sales = false, hiring_ai_all_roles = false, hiring_auto_hire_sales = false;

select test.mk_user('r23_admin', 'admin');
select test.mk_user('r23_cs', 'va', 'cs');
select test.mk_owner('r23_owner');
select test.mk_vehicle('r23_car', 'r23_owner');
select test.mk_vehicle('r23_car2', 'r23_owner');
select test.mk_renter('r23_renter');

-- ================================================================ 1. IndexNow (0220)
update program_settings set indexnow_enabled = true, indexnow_batch = 10000, indexnow_daily_max = 2000000 where id = (app.settings()).id;
update site_settings set indexnow_key = md5('r23') where indexnow_key is null;
delete from indexnow_queue where true;
update indexnow_sweep set backoff_until = null, backoff_s = 0, q_backoff_until = null, q_backoff_s = 0, streak_429 = 0, next_round_at = null,
       phase = 'priority', p_i = 0, p_pos = 0, file_i = 0, pos = -1, sent_today = 0, day = (now() at time zone 'America/Toronto')::date where id;
insert into indexnow_queue (path, reason) values ('/guides/r23-one', 'r23'), ('/cars/r23-car', 'r23');

-- the live state of October 31: the sweep refused with 429 until tomorrow
select app.server_indexnow_report('{"status": 429, "count": 10000, "error": "{\"errorCode\":\"TooManyRequests\"}"}');
select test.ok('the sweep''s 429 holds the sweep', (select backoff_until > now() from indexnow_sweep));
select test.ok('the changed pages are still claimed (their own back-off)', app.server_seo_claim('r23', 0) #> '{indexnow,paths}' @> '["/guides/r23-one", "/cars/r23-car"]'::jsonb);
select test.ok('and the tick runs the search job for them', (app.server_jobs_due() ->> 'seo')::boolean);
update indexnow_sweep set backoff_until = null, backoff_s = 0 where id;
select test.eq('the sweep waits while changed pages wait', app.server_indexnow_claim(100) ->> 'why', 'changed pages first');

select app.server_indexnow_sent('{"paths": ["/guides/r23-one", "/cars/r23-car"], "status": 429, "error": "TooManyRequests"}');
select test.ok('a 429 on the changed pages: an hour, and the sweep''s back-off untouched',
  (select q_backoff_until between now() + interval '55 minutes' and now() + interval '65 minutes' and backoff_until is null from indexnow_sweep));
select test.eq('while they wait nothing of theirs is claimed', app.server_seo_claim('r23', 0) #> '{indexnow,paths}', '[]'::jsonb);
update indexnow_sweep set q_backoff_until = null where id;
select app.server_indexnow_sent('{"paths": ["/guides/r23-one"], "status": 429}');
select test.ok('the next 429 in a row doubles the wait', (select q_backoff_s = 7200 from indexnow_sweep));
update indexnow_sweep set q_backoff_until = null where id;
select app.server_indexnow_sent('{"paths": ["/guides/r23-one", "/cars/r23-car"], "status": 202}');
select test.ok('a 2xx sends them and clears their back-off', (select q_backoff_until is null and q_backoff_s = 0 and q_last_status = 202 from indexnow_sweep)
  and not exists (select 1 from indexnow_queue where path like '%r23%' and sent_at is null));

-- the search scope: Full by default (every address may be sent), Core keeps to the crawl scope
select test.eq('the search scope is Full by default', (select search_scope from program_settings where id = (app.settings()).id), 'full');
select test.ok('Full: every address is in', app.crawl_scope_ok('/t/buffing/audi/a4/2021') and app.crawl_scope_ok('/places/3') and app.crawl_scope_ok('/car-rental/weekly/toronto'));
select test.eq('the tick hands the scope to the Worker', app.server_jobs_due() ->> 'search_scope', 'full');
update program_settings set search_scope = 'core' where id = (app.settings()).id;
select test.ok('crawl scope: the trees that multiply are out',
  not app.crawl_scope_ok('/t/buffing/audi/a4/2021') and not app.crawl_scope_ok('/buy/honda') and not app.crawl_scope_ok('/cars/audi/a4/2021/s-line/toronto')
  and not app.crawl_scope_ok('/car-rental/weekly/toronto') and not app.crawl_scope_ok('/car-rental/r23-nowhere-oh') and not app.crawl_scope_ok('/places/3'));
select test.ok('crawl scope: the vehicle tree to the trim, the fleet and the guides are in',
  app.crawl_scope_ok('/cars/audi/a4/2021/s-line') and app.crawl_scope_ok('/cars/r23-car') and app.crawl_scope_ok('/guides/x') and app.crawl_scope_ok('/'));
delete from indexnow_queue where sent_at is null;
update indexnow_sweep set phase = 'places', p_i = 3 where id;
select test.eq('past the priority list the round is done: the next waits a week', app.server_indexnow_claim(100) ->> 'why', 'next round');
select test.ok('back at the start of the priority list', (select phase = 'priority' and p_pos = 0 and next_round_at > now() + interval '6 days' from indexnow_sweep));
select test.eq('the tick says Core', app.server_jobs_due() ->> 'search_scope', 'core');
update program_settings set search_scope = 'full' where id = (app.settings()).id;
update indexnow_sweep set next_round_at = null, streak_429 = 1, backoff_until = null where id;
select app.server_indexnow_report('{"status": 429, "count": 5}');
select test.ok('a second 429 in a row adds a day', (select streak_429 = 2 and backoff_until > now() + interval '1 day' from indexnow_sweep));
update indexnow_sweep set backoff_until = null, backoff_s = 0, streak_429 = 0, next_round_at = null, q_backoff_until = null, q_backoff_s = 0, phase = 'priority', p_pos = 0 where id;
update program_settings set indexnow_enabled = false where id = (app.settings()).id;

select test.ok('the tick says whether the CPU guard is up', (app.server_jobs_due() ? 'cpu_guard'));

-- ================================================================ 2. usage alerts texted (0221)
update users set phone = '+14165550123', phone_verified_at = now() where id = test.id('r23_admin');
delete from usage_alerts where service = 'workers_cpu';
-- past the red line whatever the day of the month (the projection of the month so far is smaller later in the month)
create temp table r23red as select id, usage_banner_red_usd r from program_settings;
update program_settings set usage_banner_red_usd = 0;
insert into usage_alerts (service, period_start, level, used, included) values ('workers_cpu', date_trunc('month', app.local_date(now()))::date, 100, 1090000000, 30000000);
create temp table r23q as select uptime_quiet_from_hour f, uptime_quiet_until_hour u from app.settings();
update program_settings set uptime_quiet_from_hour = 0, uptime_quiet_until_hour = 0 where id = (app.settings()).id;
select app.usage_send_texts(now());
select test.ok('a 100% alert is texted to each Admin with a verified phone',
  exists (select 1 from phone_outbox where dedupe_key like 'usage_text:workers_cpu:100:%' || test.id('r23_admin')::text and body like 'CarmaCars: Website CPU time at%'));
select app.usage_send_texts(now());
select test.eq('once per figure and level a month', (select count(*) from phone_outbox where dedupe_key like 'usage_text:workers_cpu:100:%' || test.id('r23_admin')::text), 1::bigint);
select test.ok('the banner shows a figure past its allowance', jsonb_typeof(app.usage_banner(test.id('r23_admin'))) = 'array');
select test.throws('only Admins read the banner', $$ select app.usage_banner(test.id('r23_cs')) $$, 'Admin');
update program_settings p set usage_banner_red_usd = x.r from r23red x where x.id = p.id;
select test.ok('a 70% level exists for the CPU time', (select warn_bps = 7000 from usage_services where service = 'workers_cpu'));

-- ================================================================ 3. Cloudflare email first (0222)
update program_settings set cf_email_enabled = true, email_cloudflare_enabled = true;  -- off for the other suites (helpers.sql)
select test.ok('the sender tries Cloudflare (on, under the month''s 3,000)', app.cf_email_try());
-- 0535: Cloudflare gets its chance before its first send (the claim held every email until it had sent, so it never did)
select test.ok('while Cloudflare may send, Resend''s limits hold nothing, before its first send too', app.cf_email_available());
select test.ok('an email held by a limit waits 15 minutes while Cloudflare has budget today', app.email_hold_until(now(), now() + interval '10 hours') <= now() + interval '15 minutes');
update program_settings set cf_email_daily_budget = 0;  -- 1750: Cloudflare's day is cf_email_daily_budget
select test.ok('Cloudflare''s day''s budget used: Resend''s limits hold again', not app.cf_email_available());
select test.ok('and a held email waits for midnight', app.email_hold_until(now(), now() + interval '10 hours') = now() + interval '10 hours');
update program_settings set cf_email_daily_budget = 100;
select public.server_cf_email_result('{"ok": true}');
select test.ok('once it sends, Resend''s limits are lifted', app.cf_email_available());
select public.server_cf_email_result('{"ok": false, "error": "no EMAIL binding"}');
select test.ok('after a refusal it rests 15 minutes', not app.cf_email_try() and not app.cf_email_available());
update email_provider_state set cf_failed_at = now() - interval '20 minutes', cf_ok_at = null where id;
select test.ok('then it may try again', app.cf_email_try());
select test.ok('Settings > Usage counts the Cloudflare emails', exists (select 1 from usage_services where service = 'cf_email' and included = 3000));
update program_settings set cf_email_enabled = false;

-- ================================================================ 4. hiring decisions (0226)
insert into job_applications (role_id, status, full_name, email) select id, 'interviewed', 'R23 Field Person', 'field@r23.example.test' from hiring_roles where slug = 'field-staff';
insert into job_applications (role_id, status, full_name, email) select id, 'interviewed', 'R23 Remote Person', 'remote@r23.example.test' from hiring_roles where slug = 'va-customer-service';
create function test.r23app(p text) returns uuid language sql stable as $$ select id from job_applications where email = p $$;
insert into interview_scores (application_id, decision, interviewer) values (test.r23app('field@r23.example.test'), 'sales', test.id('r23_admin'));
insert into interview_scores (application_id, decision, interviewer) values (test.r23app('remote@r23.example.test'), 'no', test.id('r23_admin'));
select test.eq('the rubric''s Sales instead: in person for Field staff', (select r.slug from hiring_decisions d join hiring_roles r on r.id = d.sales_role_id
  where d.application_id = test.r23app('field@r23.example.test')), 'sales-in-person');
select test.eq('No is the polite decline', (select email_code from hiring_decisions where application_id = test.r23app('remote@r23.example.test')), 'applicant_declined');
select test.eq('nothing is emailed when the decision is recorded',
  (select count(*) from app_events where entity = 'job_application' and entity_id in (test.r23app('field@r23.example.test'), test.r23app('remote@r23.example.test'))), 0::bigint);
select test.eq('the list shows both waiting', (app.hiring_decisions_read(test.id('r23_admin'), '{}'::jsonb) ->> 'waiting')::integer >= 2, true);
select test.ok('Send all can be scheduled', (app.hiring_decisions_send(test.id('r23_admin'), jsonb_build_object('when', (now() + interval '2 days')::text)) ->> 'scheduled')::integer >= 2);
select app.hiring_decisions_send(test.id('r23_admin'), '{}'::jsonb);
select test.eq('sent: one email each, the statuses follow',
  (select string_agg(a.status, ',' order by a.email) from job_applications a where a.email like '%@r23.example.test'), 'referred,rejected');
select app.hiring_decisions_send(test.id('r23_admin'), '{}'::jsonb);
select test.eq('never twice', (select count(*) from app_events where entity = 'job_application' and entity_id in (test.r23app('field@r23.example.test'), test.r23app('remote@r23.example.test'))), 2::bigint);
select test.throws('a decision sent cannot be undone', $$ select app.hiring_decision_undo(test.id('r23_admin'), jsonb_build_object('id', test.r23app('remote@r23.example.test'))) $$, 'sent already');
select test.ok('the hire and no-show emails are in the catalogue', (select count(*) = 2 from notification_catalogue where code in ('applicant_hired', 'applicant_no_show')));

-- ================================================================ 5. calls by role, the remote call confirmed (0229)
insert into interview_days (day, start_time, end_time, mode, note) values (app.local_date(now()) + 1, '08:00', '20:00', 'phone', 'r23 day');
insert into interview_slots (day_id, starts_at, ends_at) select d.id, now() + interval '20 hours', now() + interval '20 hours 15 minutes' from interview_days d where d.note = 'r23 day';
insert into interview_slots (day_id, starts_at, ends_at) select d.id, now() + interval '21 hours', now() + interval '21 hours 15 minutes' from interview_days d where d.note = 'r23 day';
insert into job_applications (role_id, status, full_name, email, phone) select id, 'invited', 'R23 Video Person', 'video@r23.example.test', '+639170000000' from hiring_roles where slug = 'va-fleet-operations';
insert into job_applications (role_id, status, full_name, email, phone) select id, 'invited', 'R23 Phone Person', 'phone@r23.example.test', '+14165550188' from hiring_roles where slug = 'field-staff';
select test.eq('a remote role meets by video on a phone day', (app.hiring_book((select token from job_applications where email = 'video@r23.example.test'),
  (select s.id from interview_slots s join interview_days d on d.id = s.day_id where d.note = 'r23 day' order by s.starts_at limit 1))) ->> 'mode', 'video');
select test.ok('with its video link', (select meet_url like 'https://meet.jit.si/%' from job_applications where email = 'video@r23.example.test'));
update interview_days set mode = 'video' where note = 'r23 day';
select test.eq('an in-person role is called by phone on a video day', (app.hiring_book((select token from job_applications where email = 'phone@r23.example.test'),
  (select s.id from interview_slots s join interview_days d on d.id = s.day_id where d.note = 'r23 day' order by s.starts_at offset 1 limit 1))) ->> 'mode', 'phone');
select test.ok('without a video link', (select meet_url is null from job_applications where email = 'phone@r23.example.test'));

select app.job_hiring(now());
select test.ok('the remote call is asked to confirm (24 hours before), and gets no reminder', (select confirm_sent_at is not null and reminded_hour_at is not null
  from job_applications where email = 'video@r23.example.test')
  and exists (select 1 from app_events where code = 'applicant_confirm' and entity_id = (select id from job_applications where email = 'video@r23.example.test')));
select test.ok('the in-person call is not asked', (select confirm_sent_at is null from job_applications where email = 'phone@r23.example.test'));
select test.eq('the Calls tab says Waiting', app.hiring_confirm_state((select x from job_applications x where email = 'video@r23.example.test')), 'waiting');
select test.eq('one press confirms, no sign-in', (public.server_hiring_confirm((select token from job_applications where email = 'video@r23.example.test')) ->> 'ok'), 'true');
select test.eq('then Confirmed', app.hiring_confirm_state((select x from job_applications x where email = 'video@r23.example.test')), 'confirmed');
-- not confirmed in time: cancelled, the time opens again, one email
update job_applications set confirmed_at = null, confirm_sent_at = now() - interval '13 hours' where email = 'video@r23.example.test';
select app.job_hiring(now());
select test.ok('unconfirmed after 12 hours: cancelled, the slot free', (select status = 'invited' and slot_id is null and unconfirmed_at is not null from job_applications where email = 'video@r23.example.test'));
select test.eq('the candidate gets one short email', (select count(*) from app_events where code = 'applicant_unconfirmed' and entity_id = (select id from job_applications where email = 'video@r23.example.test')), 1::bigint);
select app.job_hiring(now());
select test.eq('never twice', (select count(*) from app_events where code = 'applicant_unconfirmed' and entity_id = (select id from job_applications where email = 'video@r23.example.test')), 1::bigint);
select test.eq('Cancelled on the Calls tab', app.hiring_confirm_state((select x from job_applications x where email = 'video@r23.example.test')), 'cancelled');

-- the Quo texts on Settings > Usage, at a cent each
select test.ok('Settings > Usage counts the Quo texts', exists (select 1 from usage_services where service = 'quo_texts' and usd_per_unit = 0.01));
select app.usage_measure('quo_texts', now());
select test.ok('measured from the texts sent', exists (select 1 from usage_readings where service = 'quo_texts'));

-- ================================================================ 6. a credit card by default, an Admin's override per booking (0230)
select test.mk_booking('R23-D1', 'r23_car', 'r23_renter', '2026-12-01 10:00', '2026-12-04 10:00', 'confirmed');
create function test.r23d() returns uuid language sql stable as $$ select id from bookings where booking_number = 'R23-D1' $$;
select test.ok('by default a credit card is required: debit and prepaid refused, credit taken',
  not app.booking_card_ok(test.r23d(), '{"funding": "debit"}') and not app.booking_card_ok(test.r23d(), '{"funding": "prepaid"}') and app.booking_card_ok(test.r23d(), '{"funding": "credit"}')
  and not public.booking_takes_debit(test.r23d()));
select test.throws('only an Admin allows a debit card', $$ select app.booking_allow_debit(test.id('r23_cs'), jsonb_build_object('booking_id', test.r23d(), 'reason', 'x')) $$, 'Admin');
select test.throws('with a reason', $$ select app.booking_allow_debit(test.id('r23_admin'), jsonb_build_object('booking_id', test.r23d())) $$, 'reason');
select app.door(test.id('r23_admin'), 'aal2', 'admin_do', 'booking_allow_debit', jsonb_build_object('booking_id', test.r23d(), 'reason', 'Only a debit card, deposit by e-Transfer agreed'));
select test.ok('allowed: who, when and why kept, audited; debit and prepaid taken on this booking',
  (select debit_allowed_at is not null and debit_allowed_by = test.id('r23_admin') and debit_allowed_reason like 'Only a debit card%' from bookings where id = test.r23d())
  and exists (select 1 from audit_log where action = 'booking_allow_debit' and entity_id = test.r23d()::text)
  and app.booking_card_ok(test.r23d(), '{"funding": "prepaid"}') and public.booking_takes_debit(test.r23d()));
select test.ok('the Money tab shows it', (app.booking_money(test.id('r23_admin'), jsonb_build_object('booking', 'R23-D1')) #>> '{debit,takes}')::boolean);
update bookings set coverage_option = 2 where id = test.r23d();
select test.ok('card coverage is never overridden', not app.booking_card_ok(test.r23d(), '{"funding": "debit"}'));
select test.throws('and cannot be allowed', $$ select app.booking_allow_debit(test.id('r23_admin'), jsonb_build_object('booking_id', test.r23d(), 'reason', 'x')) $$, 'credit card rental coverage');
update bookings set coverage_option = null where id = test.r23d();
select app.booking_allow_debit(test.id('r23_admin'), jsonb_build_object('booking_id', test.r23d(), 'allow', false));
select test.ok('turned off again', not app.booking_card_ok(test.r23d(), '{"funding": "debit"}'));
update program_settings set card_types_accepted = 'any' where id = (app.settings()).id;
select test.ok('the site-wide default "credit, debit and prepaid" takes them on every booking', app.booking_card_ok(test.r23d(), '{"funding": "prepaid"}'));
update program_settings set card_types_accepted = 'credit' where id = (app.settings()).id;
-- the card's type on the payment, from the saved card
insert into payment_methods (renter_id, card_brand, card_last4, cardholder_name, exp_month, exp_year, is_credit, funding)
values (test.id('renter:r23_renter'), 'visa', '5556', 'R23 Renter', 12, 2030, false, 'debit');
insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, card_brand, card_last4)
values (test.r23d(), test.id('renter:r23_renter'), 'deposit', 'hold', 'card', 50000, 'authorized', 'visa', '5556');
select test.eq('the payment keeps the card''s type', (select card_funding from payments where booking_id = test.r23d() and card_last4 = '5556'), 'debit');
select test.eq('the Money tab lists the card with its type', app.booking_money(test.id('r23_admin'), jsonb_build_object('booking', 'R23-D1')) #>> '{cards,0,funding}', 'debit');

-- ================================================================ 7. every class (0233)
select test.ok('the enum has every class of the list', not exists (select 1 from vehicle_classes c where not exists (
  select 1 from pg_enum e where e.enumtypid = 'vehicle_class'::regtype and e.enumlabel = c.code)));
insert into fee_defaults (fee_type_code, vehicle_class, amount_cents, effective_from)
  values ((select code from fee_types order by sort_order limit 1), 'van', 4321, current_date - 1);
update vehicles set class = 'van' where id = test.id('vehicle:r23_car');
select test.eq('a fee default for Van applies to a car priced as a Van',
  (select amount_cents from public.effective_fee((select code from fee_types order by sort_order limit 1), test.id('vehicle:r23_car'))), 4321::bigint);
select test.eq('Class rules list the classes in the list''s order', jsonb_array_length(app.class_rules_read(test.id('r23_admin')) -> 'classes'),
  (select count(*)::integer from vehicle_classes where is_active));

-- ================================================================ 8. adjusters (0234)
insert into insurers (name) values ('R23 Mutual'), ('R23 Other');
create function test.r23ins(p text) returns uuid language sql stable as $$ select id from insurers where name = p $$;
select test.mk_booking('R23-1', 'r23_car', 'r23_renter', '2026-10-01 10:00', '2026-10-05 10:00', 'confirmed');
select test.mk_booking('R23-2', 'r23_car2', 'r23_renter', '2026-10-10 10:00', '2026-10-12 10:00', 'confirmed');
update bookings set insurer_id = test.r23ins('R23 Mutual'), bill_to = 'insurer', insurer_adjuster_name = 'Ada Adjuster', insurer_adjuster_email = 'ada@r23.example.test'
 where id = test.id('booking:R23-1');
select test.ok('an adjuster typed on a booking is saved with the insurer',
  exists (select 1 from insurer_adjusters a join bookings b on b.insurer_adjuster_id = a.id where b.id = test.id('booking:R23-1') and a.insurer_id = test.r23ins('R23 Mutual') and a.email = 'ada@r23.example.test'));
update bookings set insurer_id = test.r23ins('R23 Mutual'), bill_to = 'insurer', insurer_adjuster_name = 'Ada A.', insurer_adjuster_email = 'ADA@r23.example.test', insurer_adjuster_phone = '416-555-0142'
 where id = test.id('booking:R23-2');
select test.eq('the same email is the same adjuster (one row), with the phone added',
  (select count(*) || '/' || max(phone) from insurer_adjusters where insurer_id = test.r23ins('R23 Mutual')), '1/416-555-0142');
select app.door(test.id('r23_admin'), 'aal2', 'admin_do', 'insurer_adjuster_save', jsonb_build_object('insurer_id', test.r23ins('R23 Other'), 'name', 'Cy Other', 'email', 'cy@r23.example.test'));
select test.throws('an adjuster of another insurer is refused', $$ update bookings set insurer_adjuster_id = (select id from insurer_adjusters where email = 'cy@r23.example.test')
  where id = test.id('booking:R23-2') $$, 'another insurer');
select app.door(test.id('r23_admin'), 'aal2', 'admin_do', 'insurer_adjuster_save', jsonb_build_object('insurer_id', test.r23ins('R23 Mutual'), 'name', 'Bo Adjuster', 'email', 'bo@r23.example.test'));
select app.booking_insurer_save(test.id('r23_cs'), jsonb_build_object('booking', 'R23-2', 'adjuster_id', (select id from insurer_adjusters where email = 'bo@r23.example.test')));
select test.eq('a saved adjuster picked on a booking fills its details', (select insurer_adjuster_email from bookings where id = test.id('booking:R23-2')), 'bo@r23.example.test');
select app.booking_insurer_save(test.id('r23_cs'), jsonb_build_object('booking', 'R23-2', 'insurer_id', 'new', 'insurer_name', 'R23 Brand New Insurance'));
select test.ok('an insurer added by name on the booking', (select insurer_id = test.r23ins('R23 Brand New Insurance') from bookings where id = test.id('booking:R23-2')));
select test.ok('billing by class, by car and by adjuster', (select b ? 'by_car' and b ? 'by_adjuster' and b ? 'class_charges' and jsonb_array_length(b -> 'by_adjuster') >= 1
  from (select app.insurer_billing(test.id('r23_admin'), jsonb_build_object('insurer', test.r23ins('R23 Mutual'))) b) x));
select test.ok('the rate sheet lists what was billed by insurer and class', app.insurer_rate_sheet(test.id('r23_admin'), '{}'::jsonb) ? 'billed');
select test.ok('an insurer needs no billing contact of its own', (select billing_email is null from insurers where id = test.r23ins('R23 Mutual')));

-- ================================================================ 9. tasks close themselves (0235)
select app.raise_task(p_type => 'live_rental_car_status', p_queue => 'fleet', p_priority => 'high', p_title => 'R23 car is out: set its status to On rent',
  p_booking => test.id('booking:R23-1'), p_vehicle => test.id('vehicle:r23_car'), p_dedupe => 'live_rental_car_status:r23');
update vehicles set status = 'on_rent' where id = test.id('vehicle:r23_car');
select test.eq('the car set to On rent closes "set its status to On rent"', (select status from tasks where dedupe_key = 'live_rental_car_status:r23'), 'done');
select app.raise_task(p_type => 'live_rental_car_status', p_queue => 'fleet', p_priority => 'high', p_title => 'R23 car is out (2)',
  p_booking => test.id('booking:R23-2'), p_vehicle => test.id('vehicle:r23_car2'), p_dedupe => 'live_rental_car_status:r23b');
update bookings set vehicle_id = test.id('vehicle:r23_car') where id = test.id('booking:R23-2');
select test.eq('the booking moved to another car closes it too', (select status from tasks where dedupe_key = 'live_rental_car_status:r23b'), 'done');

-- ================================================================ 10. the cars on sample photos (0236)
select test.ok('photos needed: a list for an Admin', jsonb_typeof(app.photos_needed(test.id('r23_admin')) -> 'cars') = 'array');
select test.throws('not for customer service', $$ select app.photos_needed(test.id('r23_cs')) $$, 'fleet');
select test.eq('the handover shots map to the listing shots', (select listing_shot from app.handover_shot_map() where handover_shot = 'instrument_cluster' and pref = 1), 'odometer');

update program_settings set uptime_quiet_from_hour = (select f from r23q), uptime_quiet_until_hour = (select u from r23q) where id = (app.settings()).id;

-- ================================================================ 11. a car's registration (0237)
select test.throws('the check digit', $$ select app.vehicle_registration_save(test.id('r23_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:r23_car2'), 'vin', '2T1BR32E14C230231')) $$, 'check digit');
select test.throws('17 characters, no I, O or Q', $$ select app.vehicle_registration_save(test.id('r23_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:r23_car2'), 'vin', '2T1BR32EX4C2302O1')) $$, '17 letters');
select app.vehicle_registration_save(test.id('r23_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:r23_car2'), 'vin', '2T1BR32EX4C230231', 'year', '2024',
  'body_type', 'Sedan', 'permit_number', 'R23 1234567', 'sticker_expires_on', (app.local_date(now()) + 25)::text));
select test.eq('VIN, year, body style, permit number and sticker saved', (select vin || '/' || year || '/' || body_type || '/' || permit_number || '/' || (sticker_expires_on - app.local_date(now())) from vehicles where id = test.id('vehicle:r23_car2')),
  '2T1BR32EX4C230231/2024/Sedan/R23 1234567/25');
select test.throws('a VIN already on another car is refused', $$ select app.vehicle_registration_save(test.id('r23_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:r23_car'), 'vin', '2T1BR32EX4C230231')) $$, 'another car');
select test.throws('customer service cannot', $$ select app.vehicle_registration_save(test.id('r23_cs'), jsonb_build_object('vehicle_id', test.id('vehicle:r23_car2'), 'year', '2020')) $$, 'fleet');
select app.job_expiry_watch(now());
select test.ok('the sticker 25 days away: a fleet task (the 30-day one), no owner billing', exists (select 1 from tasks where vehicle_id = test.id('vehicle:r23_car2') and task_type = 'sticker_renewal' and queue = 'fleet' and dedupe_key like '%:30'));
update vehicles set sticker_expires_on = app.local_date(now()) + 5 where id = test.id('vehicle:r23_car2');
select app.job_expiry_watch(now());
select test.ok('and again at 7 days', exists (select 1 from tasks where vehicle_id = test.id('vehicle:r23_car2') and task_type = 'sticker_renewal' and dedupe_key like '%:7'));
select app.vehicle_registration_save(test.id('r23_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:r23_car2'), 'sticker_expires_on', (app.local_date(now()) + 365)::text));
select test.eq('a new sticker date closes its tasks', (select count(*) from tasks where vehicle_id = test.id('vehicle:r23_car2') and task_type = 'sticker_renewal' and status = 'open'), 0::bigint);
select app.vehicle_document_register(test.id('r23_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:r23_car2'), 'kind', 'ownership_permit', 'path', 'vehicles/r23/documents/permit.pdf', 'mime', 'application/pdf'));
select test.ok('the ownership permit uploaded on the car is on file for its checklist', exists (select 1 from documents where vehicle_id = test.id('vehicle:r23_car2') and kind = 'ownership_permit' and purged_at is null));
select test.eq('the car''s documents are listed', jsonb_array_length(app.vehicle_documents_read(test.id('r23_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:r23_car2')))), 1);

-- ================================================================ 12. owner charges deducted from payouts (0238)
create temp table r23i as select app.owner_invoice_draft_save(test.id('r23_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:r23_car'), 'title', 'First and last month',
  'lines', '[{"description": "First and last month", "quantity": 1, "unit_amount_cents": 60000, "hst": true}]'::jsonb)) j;
create function test.r23inv() returns owner_invoices language sql stable as $$ select * from owner_invoices where id = (select (j ->> 'id')::uuid from r23i) $$;
select app.owner_invoice_collect_by(test.id('r23_admin'), jsonb_build_object('id', (test.r23inv()).id, 'collect_by', 'payout'));
select test.eq('deduct from payouts: the draft is issued quietly', (select collect_by || '/' || status || '/' || total_cents from owner_invoices where id = (test.r23inv()).id), 'payout/issued/67800');
select test.eq('never debited by bank', app.owner_debit_block((test.r23inv()).id), 'deducted from payouts');
select test.ok('not a debit candidate', not exists (select 1 from app.owner_debit_candidates(test.id('owner:r23_owner'), app.local_date(now()) + 60) c where c.id = (test.r23inv()).id));
select test.throws('only Admins', $$ select app.owner_invoice_collect_by(test.id('r23_cs'), jsonb_build_object('id', (test.r23inv()).id, 'collect_by', 'bank_debit')) $$, 'Admin');
-- the statement deducts it: a fees_deducted line for what the payout allows
select test.mk_booking('R23-9', 'r23_car', 'r23_renter', '2026-08-03 10:00', '2026-08-06 10:00', 'closed');
select app.build_owner_statement(test.id('owner:r23_owner'), date '2026-08-01');
select test.ok('the statement deducts it (an itemized deduction on the car, or carried forward when there is no payout)',
  exists (select 1 from owner_statement_lines l join owner_statements s on s.id = l.owner_statement_id
           where s.owner_id = test.id('owner:r23_owner') and l.owner_invoice_id = (test.r23inv()).id and l.line_type in ('fees_deducted', 'arrears_moved') and l.amount_cents < 0)
  or not exists (select 1 from owner_statement_vehicles sv join owner_statements s on s.id = sv.owner_statement_id where s.owner_id = test.id('owner:r23_owner') and sv.net_earnings_cents > 0));
select test.ok('the first and last month decision offers Deduct from payouts', (select pg_get_constraintdef(oid) like '%deduct%' from pg_constraint where conname = 'vehicle_onboardings_first_last_choice_check'));

-- ================================================================ 13. the Tracker Fee from the installation (0239)
select test.mk_vehicle('r23_notrk', 'r23_owner', p_enrolled => date '2026-09-01');
update vehicles set tracker_installed_on = null, tracker_install_pending = false where id = test.id('vehicle:r23_notrk');
select app.generate_owner_invoice(test.id('vehicle:r23_notrk'), date '2026-10-01', test.id('r23_admin'));
select test.eq('no tracker installed: no Tracker Fee on the monthly invoice',
  (select coalesce(sum(l.amount_cents), 0) from owner_invoice_lines l join owner_invoices i on i.id = l.owner_invoice_id
    where i.vehicle_id = test.id('vehicle:r23_notrk') and i.period_month = date '2026-10-01' and l.kind = 'tracker_fee'), 0::numeric);
update vehicles set tracker_installed_on = date '2026-11-16' where id = test.id('vehicle:r23_notrk');
select app.generate_owner_invoice(test.id('vehicle:r23_notrk'), date '2026-11-01', test.id('r23_admin'));
select test.ok('installed on the 16th: the first month prorated from the install date',
  (select sum(l.amount_cents) between 1 and 2499 from owner_invoice_lines l join owner_invoices i on i.id = l.owner_invoice_id
    where i.vehicle_id = test.id('vehicle:r23_notrk') and i.period_month = date '2026-11-01' and l.kind = 'tracker_fee'));
select test.ok('the audit lists what was charged without an installation', (app.tracker_fee_audit(test.id('r23_admin')) ? 'charged_cents'));

-- ================================================================ 14. the Safety Standards Certificate, a car moved to another owner (0237)
select app.vehicle_document_register(test.id('r23_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:r23_car2'), 'kind', 'safety_certificate', 'path', 'vehicles/r23/documents/ssc.pdf',
  'mime', 'application/pdf', 'number', 'r23ssc01', 'issued_on', (app.local_date(now()) - 340)::text, 'expires_on', (app.local_date(now()) + 20)::text));
select test.eq('the certificate''s number and dates are on the car, with its document', (select ssc_number || '/' || (ssc_expires_on - ssc_issued_on) from vehicles where id = test.id('vehicle:r23_car2')), 'R23SSC01/360');
select test.ok('a document, not a service record', exists (select 1 from documents where vehicle_id = test.id('vehicle:r23_car2') and kind = 'safety_certificate'));
select app.job_expiry_watch(now());
select test.ok('20 days before it expires: a fleet task', exists (select 1 from tasks where vehicle_id = test.id('vehicle:r23_car2') and task_type = 'ssc_renewal' and queue = 'fleet' and status = 'open'));
select test.throws('the expiry after the issue date', $$ select app.vehicle_document_register(test.id('r23_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:r23_car2'), 'kind', 'safety_certificate',
  'path', 'vehicles/r23/documents/ssc2.pdf', 'mime', 'application/pdf', 'issued_on', '2026-10-01', 'expires_on', '2026-09-01')) $$, 'after the issue date');

select test.mk_owner('r23_owner2');
select test.mk_vehicle('r23_moved', 'r23_owner');
update vehicle_schedules set signed_at = null where vehicle_id = test.id('vehicle:r23_moved');
select app.owner_invoice_draft_save(test.id('r23_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:r23_moved'), 'title', 'First and last month',
  'lines', '[{"description": "First and last month", "quantity": 1, "unit_amount_cents": 60000, "hst": true}]'::jsonb));
select test.throws('only Admins move a car', $$ select app.vehicle_move_owner(test.id('r23_cs'), jsonb_build_object('vehicle_id', test.id('vehicle:r23_moved'), 'owner_id', test.id('owner:r23_owner2'))) $$, 'Admin');
select test.throws('a car with a signed schedule stays with its owner', $$ select app.vehicle_move_owner(test.id('r23_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:r23_car2'), 'owner_id', test.id('owner:r23_owner2'))) $$, 'signed');
create temp table r23m as select app.vehicle_move_owner(test.id('r23_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:r23_moved'), 'owner_id', test.id('owner:r23_owner2'))) j;
select test.eq('moved: the new owner, the unsigned schedule withdrawn and kept, the draft invoice deleted',
  (select (j ->> 'schedules_withdrawn') || '/' || (j ->> 'draft_invoices_deleted') from r23m)
  || '/' || (select (owner_id = test.id('owner:r23_owner2'))::text from vehicles where id = test.id('vehicle:r23_moved'))
  || '/' || (select count(*) from vehicle_schedules where vehicle_id = test.id('vehicle:r23_moved') and withdrawn_at is not null)
  || '/' || (select count(*) from owner_invoices where vehicle_id = test.id('vehicle:r23_moved')), '1/1/true/1/0');
select test.ok('no notice to either owner', not exists (select 1 from notification_outbox e where e.vehicle_id = test.id('vehicle:r23_moved')));
select app.vehicle_move_owner(test.id('r23_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:r23_moved'), 'to', 'company'));
select test.eq('an unknown owner: the car is CarmaCars'' own', (select supply_type || '/' || (owner_id = app.company_owner_id())::text from vehicles where id = test.id('vehicle:r23_moved')), 'company/true');
select test.throws('the first car (signed, its invoice issued) stays with its owner', $$ select app.vehicle_move_owner(test.id('r23_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:r23_car'), 'owner_id', test.id('owner:r23_owner2'))) $$, 'signed');
