-- 99: Admin > To do counts what needs the Admin, usage banners speak in money, staff emails while a function is unstaffed
-- go to the Admin's digest, and the search snapshots write nothing when nothing changed (0320).
-- docs/changes/2026-11-06-owner-todo-usage-noise.md. Fixtures start with "on" and use example.test only.
select test.suite('99 owner To do, usage in money, email noise');

select test.mk_user('on_admin', 'admin');
select test.mk_owner('on_olive');

-- ================================================================ 1. 200 unfinished forms do not add 200 to "need you"
create temp table on_before as select (app.admin_todo(test.id('on_admin')) ->> 'need')::integer need;
select test.ok('the read says how many things need the Admin', (select need from on_before) is not null);

-- the follow-ups, as the job raises them at noon (it never raises them in the quiet hours)
insert into contact_captures (visitor_id, form, ref, name, email, first_at, last_at)
select gen_random_uuid(), 'contact', 'on-' || g, 'On Person ' || g, 'on.person' || g || '@example.test',
       app.local_midnight(app.today()) + interval '11 hours', app.local_midnight(app.today()) + interval '11 hours 10 minutes'
  from generate_series(1, 200) g;
select app.job_capture(app.local_midnight(app.today()) + interval '12 hours');
select test.eq('200 follow-ups raised', (select count(*) from tasks t join contact_captures c on c.task_id = t.id where c.email like 'on.person%@example.test'), 200::bigint);
select test.eq('all in Sales'' queue, none in the Admin''s',
  (select string_agg(distinct t.queue, ',') from tasks t join contact_captures c on c.task_id = t.id where c.email like 'on.person%@example.test'), 'sales');

create temp table on_todo as select app.admin_todo(test.id('on_admin')) v;
select test.eq('"need you" does not grow by 200 (not even by one)', (select (v ->> 'need')::integer from on_todo), (select need from on_before));
select test.ok('no follow-up comes to the Admin as a prompt',
  not exists (select 1 from on_todo, jsonb_array_elements(v -> 'prompts') p where p ->> 'task_type' = 'capture_follow_up'));
select test.eq('the count line is Sales''',
  (select i ->> 'team' from on_todo, jsonb_array_elements(v -> 'items') i where i ->> 'key' = 'capture_follow_up'), 'sales');
select test.ok('Sales'' line says how many are open, and links to their queue',
  (select (t ->> 'open')::integer >= 200 and t ->> 'href' = '/admin/tasks?queue=sales' and t -> 'items' @> '[{"key": "capture_follow_up"}]'
     from on_todo, jsonb_array_elements(v -> 'teams') t where t ->> 'key' = 'sales'));
select test.eq('one line per team', (select string_agg(t ->> 'key', ',' order by n) from on_todo, jsonb_array_elements(v -> 'teams') with ordinality x(t, n)), 'cs,sales,fleet,finance');
select test.ok('every queue is still reachable: the Leads list keeps every person',
  (select count(*) from contact_captures where email like 'on.person%@example.test' and done_at is null) = 200);

-- ================================================================ 2. many tasks of one kind are one line; a staff queue's are its team's
select app.raise_task(p_type => 'check_owner_document', p_title => 'On: check an owner document ' || g, p_queue => 'admin', p_dedupe => 'on:doc:' || g)
  from generate_series(1, 30) g;
select test.eq('30 Admin tasks of one kind: one more line', (app.admin_todo(test.id('on_admin')) ->> 'need')::integer, (select need from on_before) + 1);
select app.raise_task(p_type => 'check_owner_document', p_title => 'On: customer service ' || g, p_queue => 'cs', p_dedupe => 'on:cs:' || g)
  from generate_series(1, 40) g;
select test.eq('40 customer service tasks: none in "need you", staffed or not', (app.admin_todo(test.id('on_admin')) ->> 'need')::integer, (select need from on_before) + 1);
select test.ok('customer service''s line counts them',
  (select (t ->> 'open')::integer >= 40 from jsonb_array_elements(app.admin_todo(test.id('on_admin')) -> 'teams') t where t ->> 'key' = 'cs'));
select test.eq('the headline rule: a repeated kind is one line, a decision about one booking is one line each',
  app.todo_need('[{"kind": "photos"}, {"kind": "photos"}, {"kind": "photos"}, {"kind": "requests"}, {"kind": "requests"}]'::jsonb,
                '[{"key": "maintenance_unknown", "count": 12, "team": "fleet"}, {"key": "countersign", "count": 4}, {"key": "requests", "count": 2}]'::jsonb), 4);

-- ================================================================ 3. follow-ups close after the window; the person stays
update tasks t set created_at = now() - interval '8 days' from contact_captures c where c.task_id = t.id and c.email in ('on.person1@example.test', 'on.person2@example.test');
select test.eq('past seven days: two follow-ups close by themselves', app.capture_followups_expire(), 2);
select test.eq('they say why', (select min(t.completion_note) from tasks t join contact_captures c on c.task_id = t.id where c.email = 'on.person1@example.test'),
  'Closed by itself after 7 days: the person stays on Admin > Leads');
select test.eq('their captures stay', (select count(*) from contact_captures where email in ('on.person1@example.test', 'on.person2@example.test')), 2::bigint);

-- ================================================================ 4. usage: red from a projected cost of US$5 a month, a quiet note under it
delete from usage_alerts where service in ('workers_cpu', 'r2_storage');
select app.usage_put('workers_cpu', app.today(), 'cloudflare', 0);
select test.eq('under the allowance: no banner line', (select count(*) from jsonb_array_elements(app.usage_banner(test.id('on_admin'))) b where b ->> 'service' = 'workers_cpu'), 0::bigint);
select app.usage_put('workers_cpu', app.today(), 'cloudflare', 36899350);
-- 123% of the month's CPU time at the month's end: about US$0.14 above it, projected about the same
select test.ok('at the month''s end, a few cents projected: a quiet note, not red',
  (select m ->> 'tone' = 'note' and (m ->> 'projected_usd')::numeric between 0.10 and 0.20
     from app.usage_money('workers_cpu', app.local_midnight((app.month_start(app.today()) + interval '1 month')::date) - interval '1 hour') m));
select test.eq('the note: 123% used early in the month projects above US$5? red only then',
  (select b ->> 'tone' from jsonb_array_elements(app.usage_banner(test.id('on_admin'))) b where b ->> 'service' = 'workers_cpu'),
  case when (app.usage_money('workers_cpu') ->> 'projected_usd')::numeric >= 5 then 'red' else 'note' end);
update program_settings set usage_banner_red_usd = 1000;
select test.eq('with the red line at US$1,000 (Program settings): a quiet note',
  (select b ->> 'tone' from jsonb_array_elements(app.usage_banner(test.id('on_admin'))) b where b ->> 'service' = 'workers_cpu'), 'note');
select test.ok('and no card under To do', not ((app.usage_cards(test.id('on_admin')) -> 'cards') @> '[{"service": "workers_cpu"}]'));
insert into usage_alerts (service, period_start, level, used, included) values ('workers_cpu', app.month_start(app.today()), 100, 36899350, 30000000);
select test.ok('its alert is kept but neither emailed nor texted, and says why',
  (select emailed_at is not null and texted_at is not null and email_note like 'not emailed: projected about US$%' from usage_alerts where service = 'workers_cpu' and level = 100));
update program_settings set usage_banner_red_usd = 0.01;
select test.eq('over the red line: red', (select b ->> 'tone' from jsonb_array_elements(app.usage_banner(test.id('on_admin'))) b where b ->> 'service' = 'workers_cpu'), 'red');
update program_settings set usage_banner_red_usd = 5;
select test.eq('the AI hard stop is unchanged (not priced in this rule)', app.usage_money('workers_ai') ->> 'priced', 'false');
select app.usage_put('resend_day', app.today(), 'app', 98);
select test.ok('emails at 98 of 100: still on the banner (they are held at 100), with whether Cloudflare sends',
  (select b ->> 'tone' = 'amber' and b -> 'cf' ->> 'state' is not null from jsonb_array_elements(app.usage_banner(test.id('on_admin'))) b where b ->> 'service' = 'resend_day'));
select app.usage_put('resend_day', app.today(), 'app', 0);

-- ================================================================ 5. Cloudflare Email Service: absent, failing, sending
create temp table on_cf as select cf_ok_at, cf_failed_at, cf_error from email_provider_state limit 1;
update program_settings set cf_email_enabled = true;  -- off for the other suites (helpers.sql)
update email_provider_state set cf_ok_at = null, cf_failed_at = now(), cf_error = 'no EMAIL binding on the Worker (Email Service not set up)';
select test.eq('never sent, no binding: absent', app.cf_email_setup() ->> 'state', 'absent');
update email_provider_state set cf_ok_at = now() - interval '2 hours', cf_failed_at = now() - interval '1 hour', cf_error = 'domain not verified';
select test.eq('sent before, refused since: failing', app.cf_email_setup() ->> 'state', 'failing');
update email_provider_state set cf_ok_at = now(), cf_failed_at = null, cf_error = null;
select test.eq('sending: ok', app.cf_email_setup() ->> 'state', 'ok');
select test.eq('Admins read it through the door', app.door(test.id('on_admin'), 'aal2', 'ops_read', 'usage_email_setup', '{}') ->> 'state', 'ok');
-- the provider state as it was (later suites start from it)
update email_provider_state e set cf_ok_at = o.cf_ok_at, cf_failed_at = o.cf_failed_at, cf_error = o.cf_error from on_cf o;
update program_settings set cf_email_enabled = false;

-- ================================================================ 6. unstaffed functions: the Admin's copy goes in the digest
create temp table on_va as select user_id, is_active from staff_profiles where staff_type = 'va';
update staff_profiles set is_active = false where staff_type = 'va';
update site_settings set admin_allowed_emails = admin_allowed_emails || array['on_admin@example.test'] where singleton;
select test.eq('a customer service email''s Admin copy is not immediate',
  (select bool_or(r.immediate) from notification_catalogue c,
     lateral app.notification_recipients(row(0, 'staff_identity_review', 'booking', gen_random_uuid(), '{}'::jsonb, null, null, now(), null, null)::app_events, c) r
   where c.code = 'staff_identity_review' and r.audience = 'staff_admin'), false);
update site_settings set admin_allowed_emails = array_remove(admin_allowed_emails, 'on_admin@example.test') where singleton;
update staff_profiles s set is_active = g.is_active from on_va g where g.user_id = s.user_id;
select test.ok('a live chat waiting stays immediate', app.staff_fallback_urgent('staff_chat_waiting') and not app.staff_fallback_urgent('staff_identity_review'));

-- ================================================================ 7. the search snapshots write nothing when nothing changed
select app.seo_snapshot_refresh();
create temp table on_xmin as select slug, xmin::text x from place_terms;
select app.seo_snapshot_refresh();
select test.eq('a second run rewrites no rental term', (select count(*) from place_terms p join on_xmin o on o.slug = p.slug where p.xmin::text <> o.x), 0::bigint);



-- ================================================================ 8. owner steps (0321): what waits on the owner, with the step; never a value
select test.ok('the features waiting on an owner step are listed with their step',
  (select bool_and(x ? 'feature' and length(x ->> 'step') > 40) from jsonb_array_elements(app.owner_steps()) x));
select test.ok('the RentalCoverage link while it is not set', app.owner_steps() @> '[{"key": "rentalcoverage"}]'
  = not coalesce((select app.coverage_affiliate_usable(a) from coverage_affiliate a limit 1), false));
select test.ok('no secret value is ever in it', app.owner_steps()::text !~ 'BEGIN|PRIVATE KEY');
select test.throws('service role only', $$set local role authenticated; select public.server_owner_steps()$$, 'permission denied');

-- ================================================================ 9. the crawler guard (0324): on past US$40 projected, for the rest of the month
create temp table on_cpu as select coalesce((app.usage_state('workers_cpu') ->> 'used')::numeric, 0) v;
update program_settings set crawler_guard_month = null where id = (app.settings()).id;
select app.usage_put('workers_cpu', app.today(), 'cloudflare', 0);
select test.eq('under the line: off, and the tick says so', (app.crawler_guard_check() or (app.server_jobs_due() ->> 'cpu_guard')::boolean), false);
select test.ok('robots.txt reads it', public.crawler_guard() = false);
-- three billion CPU ms this month: far past US$40 projected
select app.usage_put('workers_cpu', app.today(), 'cloudflare', 3000000000);
select test.eq('past the line: on, and the Worker''s tick carries it', app.crawler_guard_check()::text || '/' || (app.server_jobs_due() ->> 'cpu_guard'), 'true/true');
select test.ok('Admin > To do says so, with the line and the end of the month',
  (select (v -> 'crawler_guard' ->> 'line_usd')::numeric = 40 and (v -> 'crawler_guard' ->> 'until')::date = (app.month_start(app.today()) + interval '1 month')::date
     from (select app.admin_todo(test.id('on_admin')) v) x));
select app.usage_put('workers_cpu', app.today(), 'cloudflare', 0);
select test.ok('it stays on for the rest of the month when the CPU falls', app.crawler_guard_on() and app.crawler_guard_check());
select test.eq('and is off next month', app.crawler_guard_on(app.local_midnight((app.month_start(app.today()) + interval '1 month')::date) + interval '1 hour'), false);
update program_settings set crawler_guard_month = null where id = (app.settings()).id;
select test.ok('the hourly usage job checks it', app.job_usage_refresh() ? 'crawler_guard');
update program_settings set crawler_guard_month = null where id = (app.settings()).id;
-- the CPU figure as it was (later suites start from it)
select app.usage_put('workers_cpu', app.today(), 'cloudflare', (select v from on_cpu));

-- ================================================================ 10. the greeting name (0324)
select test.eq('no greeting name: the account''s name', public.my_roles(test.id('on_admin')) ->> 'greeting', (select full_name from users where id = test.id('on_admin')));
select test.eq('saved on My profile', app.door(test.id('on_admin'), 'aal2', 'admin_do', 'my_greeting_save', '{"greeting_name": "  Abbas and Mahad "}') ->> 'greeting', 'Abbas and Mahad');
select test.eq('the frame and the roles carry it', (public.admin_gate(test.id('on_admin')) ->> 'greeting') || '/' || (public.my_roles(test.id('on_admin')) ->> 'greeting'), 'Abbas and Mahad/Abbas and Mahad');
select test.eq('emptied: the account''s name again', app.door(test.id('on_admin'), 'aal2', 'admin_do', 'my_greeting_save', '{"greeting_name": ""}') ->> 'greeting_name', null);
select test.throws('at most 60 characters', format($$select app.my_greeting_save(%L, jsonb_build_object('greeting_name', repeat('x', 61)))$$, test.id('on_admin')), '60');
select test.throws('Admins only through the door', $$select app.door(gen_random_uuid(), 'aal2', 'admin_read', 'my_profile', '{}')$$, '');

-- ================================================================ 11. the staff queue (0325): one task per piece of work, closed with its booking
select test.mk_vehicle('on_car', 'on_olive');
select test.mk_renter('on_rita');
select app.raise_task(p_type => 'visitor_follow_up', p_title => 'Call or message Rita: started a booking request for the car and stopped',
  p_vehicle => test.id('vehicle:on_car'), p_renter => test.id('renter:on_rita'), p_queue => 'sales', p_dedupe => 'on:visit:1');
select app.raise_task(p_type => 'visitor_follow_up', p_title => 'Call or message Rita: started a booking request for the car and stopped',
  p_vehicle => test.id('vehicle:on_car'), p_renter => test.id('renter:on_rita'), p_queue => 'sales', p_dedupe => 'on:visit:2');
select test.eq('the same follow-up from a second visit: one open task, the other merged',
  (select count(*) filter (where status in ('open', 'in_progress', 'waiting')) || '/' || count(*) filter (where completion_note like 'Merged%')
     from tasks where dedupe_key in ('on:visit:1', 'on:visit:2')), '1/1');
-- an offer that expires soon, then accepted (the renter approved and the booking waits for payment)
select test.mk_booking('ON-PAY', 'on_car', 'on_rita', to_char(now() at time zone 'America/Toronto' + interval '20 days', 'YYYY-MM-DD 10:00'),
  to_char(now() at time zone 'America/Toronto' + interval '22 days', 'YYYY-MM-DD 10:00'), 'pending_payment');
select app.raise_task(p_type => 'chase_offer', p_title => 'Booking ON-PAY: the offer expires soon', p_booking => test.id('booking:ON-PAY'), p_queue => 'sales', p_dedupe => 'on:chase');
select app.raise_task(p_type => 'verify_renter', p_title => 'Check Rita''s licence for ON-PAY', p_booking => test.id('booking:ON-PAY'), p_queue => 'cs', p_dedupe => 'on:verify');
select app.tasks_close_stale(now(), test.id('booking:ON-PAY'));
select test.eq('the offer accepted: "expires soon" closes; the licence task stays (the booking is live)',
  (select string_agg(task_type || '=' || status, ',' order by task_type) from tasks where dedupe_key in ('on:chase', 'on:verify')), 'chase_offer=done,verify_renter=open');
update bookings set status = 'cancelled' where id = test.id('booking:ON-PAY');
select test.eq('the booking cancelled: the licence task closes at once', (select status from tasks where dedupe_key = 'on:verify'), 'cancelled');
-- a follow-up past the window
select app.raise_task(p_type => 'visitor_follow_up', p_title => 'Reach out to Rita: viewing spree', p_renter => test.id('renter:on_rita'), p_queue => 'sales', p_dedupe => 'on:spree');
update tasks set created_at = now() - interval '8 days' where dedupe_key = 'on:spree';
select test.ok('the hourly hygiene closes a follow-up past 7 days', (app.job_task_hygiene() ->> 'follow_ups')::integer >= 1);
select test.eq('and says why', (select status || '|' || left(completion_note, 33) from tasks where dedupe_key = 'on:spree'), 'cancelled|Closed by itself after 7 days: th');
select test.ok('Licences to check: live bookings only', app.booking_live('confirmed') and app.booking_live('requested') and not app.booking_live('expired') and not app.booking_live('cancelled'));
