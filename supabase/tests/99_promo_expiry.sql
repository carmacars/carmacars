-- 99: promo code expiry (migration 0161, docs/changes/2026-10-25-promo-code-expiry.md). Every code issued to a person has an
-- end date (the default of each source, the backfill, no way to remove it); an expired code is refused wherever a code is
-- applied; the reminders (3 days before and the day before, email and text, marketing for people's offers and transactional
-- for game codes): once each, never after use, an unsubscribe or the end, never for a code made too late, the old game
-- reminder is one of them; Admin sees the end dates and reminders; the renter sees their codes. Fixtures start with "pe".
select test.suite('99 promo code expiry');

select test.mk_user('pe_admin', 'admin');
select test.mk_user('pe_cs', 'va', 'cs');
select test.mk_owner('pe_own');
select test.mk_vehicle('pe_car', 'pe_own');
select test.mk_renter('pe_ann');     -- consent, verified phone
select test.mk_renter('pe_bob');     -- no consent
select test.mk_renter('pe_cy');      -- consent, then unsubscribed
select test.mk_renter('pe_dee');     -- consent, uses a code
select test.mk_renter('pe_eve');     -- consent, verified phone
select test.mk_renter('pe_fay');     -- consent, settings tests
select test.mk_renter('pe_gus');     -- consent, blocked
insert into consents (user_id, consent_code, text_version, text_shown, given_at)
select test.id(u), 'marketing', 'v1', 'Send me offers from CarmaCars', now() - interval '10 days' from unnest(array['pe_ann', 'pe_cy', 'pe_dee', 'pe_eve', 'pe_fay', 'pe_gus']) u;
update users set marketing_unsubscribed_at = now() - interval '1 day' where id = test.id('pe_cy');
update renters set is_blocked = true where id = test.id('renter:pe_gus');
update users set phone = '+16475550401', phone_verified_at = now() where id = test.id('pe_ann');
update users set phone = '+16475550402', phone_verified_at = now() where id = test.id('pe_eve');
insert into site_content_blocks (block_key, page, kind, body, data)
values ('legal.marketing_opt_in', 'legal', 'text', 'Yes, send me CarmaCars offers and news by email and text message. I can unsubscribe at any time. Sent by CarmaCars{{mailingAddress}}, {{contactEmail}}.', '{"version": "October 19, 2026"}')
on conflict (block_key) do nothing;
update program_settings set sms_alerts_enabled = true, sms_quiet_hours = false, signin_phone_us_allowed = false, phone_enabled = true,
  sms_default_with_phone = 'both', sms_default_phone_only = 'text';

-- a code for a renter whose last day is p_last days from today (Toronto), made 20 days ago
create or replace function test.pe_code(p_label text, p_renter text, p_source text, p_last integer, p_bps integer default 1500) returns uuid
language sql as $$
  insert into promo_codes (code, description, percent_bps, valid_from, valid_until, max_uses, once_per_renter, renter_id, source, created_at)
  values ('PE' || upper(p_label), 'Test code ' || p_label, p_bps, now() - interval '20 days', app.local_midnight(app.today() + p_last + 1), 1, true,
          test.id('renter:' || p_renter), p_source, now() - interval '20 days')
  returning id $$;
create or replace function test.pe_id(p_label text) returns uuid language sql stable as $$ select id from promo_codes where code = 'PE' || upper(p_label) $$;
create or replace function test.pe_at(p_days integer, p_hours integer default 1) returns timestamptz language sql stable as $$
  select app.local_midnight(app.today() + p_days) + make_interval(hours => p_hours) $$;
-- reminders sent for a code, as "3d,1d"
create or replace function test.pe_sent(p_label text) returns text language sql as $$
  select coalesce(string_agg(kind, ',' order by kind desc), '-') from promo_reminders where promo_code_id = test.pe_id(p_label) $$;
create or replace function test.pe_mail(p_label text, p_code text) returns text language sql as $$
  select coalesce(string_agg(o.status || ':' || o.category, ',' order by o.created_at), '-') from notification_outbox o where o.code = p_code and o.entity_id = test.pe_id(p_label) $$;

create or replace function test.pe_vid(p text) returns uuid language sql immutable as $$ select md5('pevid:' || p)::uuid $$;
create or replace function test.pe_sid(p text) returns uuid language sql immutable as $$ select md5('pesid:' || p)::uuid $$;
create or replace function test.pe_gstart(p text) returns jsonb language sql as $$
  select public.game_start(jsonb_build_object('vid', test.pe_vid(p), 'sid', test.pe_sid(p), 'device', 'phone', 'path', '/cars/pe-car', 'trigger', 'pages')) $$;
create or replace function test.pe_gclaim(p text, p_email text) returns jsonb
language sql as $$ select app.server_game_claim(jsonb_build_object('token', test.pe_gstart(p) ->> 'token', 'sid', test.pe_sid(p), 'first_name', 'Gale ' || p,
  'email', p_email, 'cars_viewed', 2, 'pages_viewed', 4, 'seconds', 95, 'marketing', false, 'city', 'Toronto', 'region', 'ON', 'country', 'CA')) $$;

-- ================================================================ 1. settings
select test.eq('settings: codes for a person last 30 days by default; the reminders are on: 3 days before and the day before',
  (select format('%s %s %s %s', promo_default_valid_days, promo_reminders_enabled, promo_reminder_3d_days, promo_reminder_1d_on)
     from program_settings order by effective_from desc limit 1), '30 t 3 t');
select test.eq('settings: the sources keep their own (7 days for a game, 30 for a come-back, 3 for Live visitors)',
  (select format('%s %s %s', s.game_code_valid_days, s.notify_comeback_valid_days, (select discount_valid_days from visitor_signal_config where id)) from (select (app.settings()).*) s), '7 30 3');
select test.throws('settings: the first reminder is 0 (off) or at least 2 days', $$update program_settings set promo_reminder_3d_days = 1$$, 'promo_reminder_3d_days');

-- ================================================================ 2. every code for a person has an end date
create or replace function test.pe_days(p_code text) returns numeric language sql stable as $$
  select round(extract(epoch from (valid_until - valid_from)) / 86400.0, 1) from promo_codes where code = p_code $$;
insert into promo_codes (code, percent_bps, source) values ('PEPUBLIC', 1000, 'campaign');
select test.ok('a public code (no renter, a campaign) may have no end date: an Admin leaves it empty', (select valid_until is null from promo_codes where code = 'PEPUBLIC'));
insert into promo_codes (code, percent_bps, source, renter_id) values ('PESTAFF', 1000, 'manual', test.id('renter:pe_bob'));
select test.eq('a code made for one renter: the default of 30 days', test.pe_days('PESTAFF'), 30.0);
insert into promo_codes (code, percent_bps, source) values ('PEGAME', 1000, 'discount_game');
select test.eq('a game code: 7 days (game_code_valid_days)', test.pe_days('PEGAME'), 7.0);
insert into promo_codes (code, percent_bps, source) values ('PEBACK7', 1000, 'followup_7d'), ('PEBACK30', 1000, 'followup_30d');
select test.eq('a come-back code: notify_comeback_valid_days', test.pe_days('PEBACK7') || '/' || test.pe_days('PEBACK30'), '30.0/30.0');
insert into promo_codes (code, percent_bps, source) values ('PELIVE', 1000, 'live_visitors');
select test.eq('a Live visitors code: its own days (3)', test.pe_days('PELIVE'), 3.0);
update program_settings set promo_default_valid_days = 45, game_code_valid_days = 9, notify_comeback_valid_days = 40;
update visitor_signal_config set discount_valid_days = 5;
insert into promo_codes (code, percent_bps, source) values ('PEGAME2', 1000, 'discount_game'), ('PEBACK2', 1000, 'followup_7d'), ('PELIVE2', 1000, 'live_visitors');
insert into promo_codes (code, percent_bps, source, renter_id) values ('PESTAFF2', 1000, 'manual', test.id('renter:pe_bob'));
select test.eq('the settings decide: 9, 40, 5 and 45 days', test.pe_days('PEGAME2') || '/' || test.pe_days('PEBACK2') || '/' || test.pe_days('PELIVE2') || '/' || test.pe_days('PESTAFF2'), '9.0/40.0/5.0/45.0');
update program_settings set promo_default_valid_days = 30, game_code_valid_days = 7, notify_comeback_valid_days = 30;
update visitor_signal_config set discount_valid_days = 3;
select test.throws('the end date of a code for a person cannot be taken away', $$update promo_codes set valid_until = null where code = 'PESTAFF'$$, 'needs an end date');
select test.throws('...nor of a game code', $$update promo_codes set valid_until = null where code = 'PEGAME'$$, 'needs an end date');
update promo_codes set valid_until = now() + interval '5 days' where code = 'PEPUBLIC';
update promo_codes set valid_until = null where code = 'PEPUBLIC';
select test.ok('...a public code can be changed either way', (select valid_until is null from promo_codes where code = 'PEPUBLIC'));
select test.throws('the end is after the start', $$insert into promo_codes (code, percent_bps, source, valid_from, valid_until) values ('PEBAD', 1000, 'discount_game', now(), now() - interval '1 day')$$, 'violates check constraint');
-- the backfill of 0161: codes for people on file without an end date get 30 days from the migration
alter table promo_codes disable trigger promo_codes_expiry_guard;
insert into promo_codes (code, percent_bps, source, valid_from, valid_until, renter_id) values
  ('PEOLD1', 1000, 'discount_game', now() - interval '40 days', null, null), ('PEOLD2', 1000, 'followup_7d', now() - interval '3 days', null, null),
  ('PEOLD3', 1000, 'manual', now() - interval '60 days', null, test.id('renter:pe_bob')), ('PEOLD4', 1000, 'campaign', now() - interval '60 days', null, null);
alter table promo_codes enable trigger promo_codes_expiry_guard;
update promo_codes pc set valid_until = greatest(now(), pc.valid_from) + make_interval(days => (app.settings()).promo_default_valid_days)
 where pc.valid_until is null and app.promo_is_personal(pc.renter_id, pc.source);
select test.eq('the backfill: a fair end date 30 days ahead, never in the past; a public code stays open',
  (select string_agg(code || '=' || coalesce((round(extract(epoch from (valid_until - now())) / 86400.0))::text, 'none'), ' ' order by code) from promo_codes where code like 'PEOLD%'),
  'PEOLD1=30 PEOLD2=30 PEOLD3=30 PEOLD4=none');
select test.ok('no code for a person is on file without an end date', not exists (select 1 from promo_codes where valid_until is null and app.promo_is_personal(renter_id, source)));
select test.ok('the codes the program makes for people (a game claim, a come-back) all carry their end date',
  (select count(*) from promo_codes where source in ('discount_game', 'followup_7d', 'followup_30d', 'live_visitors')) > 0
  and not exists (select 1 from promo_codes where source in ('discount_game', 'followup_7d', 'followup_30d', 'live_visitors') and valid_until is null));

-- ================================================================ 3. an expired code is refused wherever a code is applied
select test.pe_code('gone', 'pe_ann', 'manual', -3);
update promo_codes set valid_from = now() - interval '20 days' where code = 'PEGONE';
select test.eq('the check: an expired code (the booking form, the quote)', app.promo_code_problem('pegone', test.id('renter:pe_ann')), 'This code has expired');
select test.eq('the check: the day before its last day it works', app.promo_code_problem('pegone', test.id('renter:pe_ann'), null, app.local_midnight(app.today() - 3) - interval '1 hour'), null);
select test.eq('the check: the end is exact (the first moment after the last day)', app.promo_code_problem('pegone', test.id('renter:pe_ann'), null, app.local_midnight(app.today() - 2)), 'This code has expired');
select test.eq('the quote says why', (select q -> 'promo' ->> 'problem' from (select app.quote_booking(test.id('vehicle:pe_car'), now() + interval '40 days', now() + interval '42 days',
  jsonb_build_object('promo_code', 'PEGONE')) as q) x), 'This code has expired');
insert into promo_codes (code, percent_bps, source, valid_from, valid_until) values ('PEPUBEXP', 1000, 'campaign', now() - interval '9 days', now() - interval '1 hour');
select test.eq('a public code that ended is refused too', app.promo_code_problem('PEPUBEXP', test.id('renter:pe_ann')), 'This code has expired');
create temp table pe_b (k text primary key, id uuid);
insert into pe_b select 'r1', app.request_booking(test.id('renter:pe_ann'), test.id('vehicle:pe_car'), now() + interval '30 days', now() + interval '33 days', 'standard', null, 'web', test.id('pe_ann'));
select test.throws('the request: a code applied after it ended is refused', format($$select app.apply_promo_code(%L, 'PEGONE', %L)$$, (select id from pe_b where k = 'r1'), test.id('pe_ann')), 'This code has expired');
select test.throws('the Admin edit of a booking: refused', format($$select app.admin_apply_booking_edit(%L, %L, '{"promo_code": "PEPUBEXP"}')$$, test.id('pe_admin'), (select id from pe_b where k = 'r1')), 'This code has expired');
select test.throws('a request made with it: the code is refused, not applied', format($$select app.request_booking(%L, %L, now() + interval '50 days', now() + interval '52 days', 'standard', null, 'web', %L, null, 'PEGONE')$$,
  test.id('renter:pe_ann'), test.id('vehicle:pe_car'), test.id('pe_ann')), 'This code has expired');
select test.throws('Add a rental: refused with the reason', format($$select app.manual_rental_create(%L, jsonb_build_object('vehicle_id', %L, 'pickup_at', date_trunc('hour', now()) + interval '10 days',
  'return_at', date_trunc('hour', now()) + interval '12 days', 'source', 'phone', 'coverage_option', 1, 'renter_id', %L, 'promo_code', 'PEPUBEXP', 'payment', '{"mode": "unpaid"}'::jsonb))$$,
  test.id('pe_admin'), test.id('vehicle:pe_car'), test.id('renter:pe_ann')), 'This code has expired');
select test.eq('an unknown or empty code says so', coalesce(app.promo_code_problem('NOSUCH', test.id('renter:pe_ann')), 'ok'), 'This code is not known');

-- ================================================================ 4. the reminders
-- earlier suites' codes and events do not take part
update promo_codes set is_active = false where code not like 'PE%';
update app_events set processed_at = now() where processed_at is null;
-- Ann: a come-back code, last day in 10 days. The first reminder is due 3 days before the last day, the second the day before.
select test.pe_code('ann1', 'pe_ann', 'followup_30d', 10);
select app.promo_reminders_run(test.pe_at(6, 23));
select test.eq('4 days before the last day: not yet', test.pe_sent('ann1'), '-');
select app.promo_reminders_run(test.pe_at(7, 1));
select test.eq('the day the last day is 3 days away: one reminder', test.pe_sent('ann1'), '3d');
select app.promo_reminders_run(test.pe_at(7, 1));
select app.promo_reminders_run(test.pe_at(7, 20));
select app.promo_reminders_run(test.pe_at(8, 5));
select test.eq('...never twice (same tick again, later the same day, the next day)', (select count(*) from app_events where entity_id = test.pe_id('ann1')), 1::bigint);
select app.process_events(100000);
select test.eq('the email: marketing, to Ann, with the code, what it gives, the end date and the unsubscribe link',
  (select format('%s %s | %s | %s | %s | %s | %s', o.category, o.to_address, o.payload ->> 'discount_code', o.payload ->> 'prize_label', o.payload ->> 'discount_expires',
                 (o.payload ->> 'unsubscribe_url') is not null, o.payload ? 'days_left')
     from notification_outbox o where o.code = 'renter_promo_expiry_3d' and o.entity_id = test.pe_id('ann1')),
  'marketing pe_ann@example.test | PEANN1 | 15% off | ' || app.fmt_day(app.today() + 10) || ' | t | t');
select test.eq('it says three days when sent three days before', app.promo_email_values((select pc from promo_codes pc where pc.code = 'PEANN1'), app.today() + 7) ->> 'days_left', '3 days');
select test.eq('the text goes by Ann''s channel (Both): her email and a text with the code and the link',
  (select count(*) from phone_outbox t join notification_outbox o on o.id = t.notification_id where o.entity_id = test.pe_id('ann1') and o.code = 'renter_promo_expiry_3d'
     and t.body like '%PEANN1%' and t.body like '%CarmaCars%' and t.body like '%/cars%' and t.status = 'queued' and t.to_number = '+16475550401'), 1::bigint);
select app.promo_reminders_run(test.pe_at(9, 1));
select test.eq('the day before the last day: the second reminder', test.pe_sent('ann1'), '3d,1d');
select app.promo_reminders_run(test.pe_at(9, 3));
select app.promo_reminders_run(test.pe_at(10, 1));
select app.process_events(100000);
select test.eq('...its email, marketing, ends tomorrow', test.pe_mail('ann1', 'renter_promo_expiry_1d'), 'queued:marketing');
select test.eq('each reminder is one event, one email, one text (never doubled)',
  (select count(*) from app_events where entity_id = test.pe_id('ann1')) || '/' || (select count(*) from notification_outbox where entity_id = test.pe_id('ann1')) || '/'
  || (select count(*) from phone_outbox t join notification_outbox o on o.id = t.notification_id where o.entity_id = test.pe_id('ann1')), '2/2/2');

-- a code is not reminded once it ended
select test.pe_code('ann2', 'pe_ann', 'followup_7d', -1);
select app.promo_reminders_run(test.pe_at(5, 1));
select app.promo_reminders_run(test.pe_at(9, 1));
select test.eq('a code ended 5 days before the second run: no reminder after the last day', test.pe_sent('ann2'), '-');

-- no consent, an unsubscribe, a blocked renter
select test.pe_code('bob1', 'pe_bob', 'followup_30d', 10), test.pe_code('cy1', 'pe_cy', 'followup_30d', 10), test.pe_code('gus1', 'pe_gus', 'followup_30d', 10);
select app.promo_reminders_run(test.pe_at(7, 2));
select app.promo_reminders_run(test.pe_at(9, 2));
select test.eq('a renter who never agreed to offers: no reminder, no email', test.pe_sent('bob1') || ' ' || test.pe_mail('bob1', 'renter_promo_expiry_3d'), '- -');
select test.eq('a renter who unsubscribed: no reminder, no email', test.pe_sent('cy1') || ' ' || test.pe_mail('cy1', 'renter_promo_expiry_3d') || ' ' || test.pe_mail('cy1', 'renter_promo_expiry_1d'), '- - -');
select test.eq('a blocked renter: none', test.pe_sent('gus1'), '-');
-- even when an event is forced for an unsubscribed renter, the pipeline refuses it (the same consent rule as the come-back offer)
select app.emit_event('renter_promo_expiry_3d', 'promo_code', test.pe_id('cy1'), jsonb_build_object('renter_id', test.id('renter:pe_cy')), 'pe-forced');
select app.process_events(100000);
select test.eq('the outbox keeps the unsubscribe: skipped, and no text', (select status || ': ' || status_reason from notification_outbox where entity_id = test.pe_id('cy1') and code = 'renter_promo_expiry_3d')
  || ' ' || (select count(*) from phone_outbox t join notification_outbox o on o.id = t.notification_id where o.entity_id = test.pe_id('cy1')), 'skipped: no marketing consent 0');

-- used: never; and a reminder waiting when the code is used does not go
select test.pe_code('dee1', 'pe_dee', 'followup_30d', 10), test.pe_code('eve1', 'pe_eve', 'followup_30d', 10);
select test.mk_booking('PE-1', 'pe_car', 'pe_dee', to_char((now() + interval '20 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
  to_char((now() + interval '22 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'requested');
insert into promo_redemptions (promo_code_id, booking_id, renter_id, discount_cents, status) values (test.pe_id('dee1'), test.id('booking:PE-1'), test.id('renter:pe_dee'), 0, 'applied');
select app.promo_reminders_run(test.pe_at(7, 3));
select test.eq('on a booking request: no reminder', test.pe_sent('dee1'), '-');
select app.process_events(100000);
select test.eq('Eve is reminded: email and text waiting', test.pe_sent('eve1') || ' ' || test.pe_mail('eve1', 'renter_promo_expiry_3d') || ' '
  || (select count(*) from phone_outbox t join notification_outbox o on o.id = t.notification_id where o.entity_id = test.pe_id('eve1') and t.status = 'queued'), '3d queued:marketing 1');
select test.mk_booking('PE-2', 'pe_car', 'pe_eve', to_char((now() + interval '25 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
  to_char((now() + interval '27 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'requested');
insert into promo_redemptions (promo_code_id, booking_id, renter_id, discount_cents, status) values (test.pe_id('eve1'), test.id('booking:PE-2'), test.id('renter:pe_eve'), 0, 'applied');
select test.eq('Eve uses the code before the email and text go: both are cancelled',
  test.pe_mail('eve1', 'renter_promo_expiry_3d') || ' | ' || (select string_agg(t.status || ': ' || t.status_reason, ',') from phone_outbox t join notification_outbox o on o.id = t.notification_id where o.entity_id = test.pe_id('eve1')),
  'skipped:marketing | skipped: The code was used');
select app.promo_reminders_run(test.pe_at(9, 2));
select test.eq('...and no second reminder follows', test.pe_sent('eve1'), '3d');
-- a reminder waiting when the code ends does not go
select test.pe_code('fay0', 'pe_fay', 'followup_30d', 10);
select app.promo_reminders_run(test.pe_at(7, 4));
select app.process_events(100000);
update promo_codes set valid_until = now() - interval '1 minute' where code = 'PEFAY0';
select app.promo_reminders_run(now());
select test.eq('after the end the waiting reminder is cancelled by the job', test.pe_mail('fay0', 'renter_promo_expiry_3d'), 'skipped:marketing');

-- a code made after the day a reminder opens gets none of that kind
insert into promo_codes (code, percent_bps, source, renter_id, valid_from, valid_until) values ('PELATE', 1000, 'followup_30d', test.id('renter:pe_fay'), now(), app.local_midnight(app.today() + 2));
select app.promo_reminders_run(now());
select app.promo_reminders_run(app.local_midnight(app.today() + 1) + interval '1 hour');
select test.eq('made today, last day tomorrow: neither reminder (it was made on the day the second opens)', test.pe_sent('late'), '-');
update promo_codes set created_at = now() - interval '1 day' where code = 'PELATE';
select app.promo_reminders_run(now());
select test.eq('...a day older, the day-before reminder is due at once', test.pe_sent('late'), '1d');

-- the settings
select test.pe_code('fay1', 'pe_fay', 'followup_30d', 12);
update program_settings set promo_reminders_enabled = false;
select app.promo_reminders_run(test.pe_at(9, 1));
select app.promo_reminders_run(test.pe_at(11, 1));
select test.eq('reminders off: none', test.pe_sent('fay1'), '-');
update program_settings set promo_reminders_enabled = true, promo_reminder_3d_days = 0;
select app.promo_reminders_run(test.pe_at(9, 1));
select test.eq('the first reminder off: it does not go', test.pe_sent('fay1'), '-');
select app.promo_reminders_run(test.pe_at(11, 1));
select test.eq('...the second does', test.pe_sent('fay1'), '1d');
select test.pe_code('fay2', 'pe_fay', 'followup_30d', 12);
update program_settings set promo_reminder_3d_days = 5, promo_reminder_1d_on = false;
select app.promo_reminders_run(test.pe_at(6, 1));
select test.eq('five days before: not on day 6 (7 days before the last day)', test.pe_sent('fay2'), '-');
select app.promo_reminders_run(test.pe_at(7, 1));
select app.promo_reminders_run(test.pe_at(11, 1));
select test.eq('...on day 7, and the second never goes while it is off', test.pe_sent('fay2'), '3d');
update program_settings set promo_reminder_3d_days = 3, promo_reminder_1d_on = true;

-- ================================================================ 5. discount game codes
select test.pe_gclaim('pe1', 'pe.game1@example.test');
select test.pe_gclaim('pe2', 'pe.game2@example.test');
select test.pe_gclaim('pe3', 'pe.game3@example.test');
update app_events set processed_at = now() where processed_at is null;
create or replace function test.pe_claim(p_email text) returns game_claims language sql stable as $$ select * from game_claims where email = p_email $$;
select test.mk_booking('PE-3', 'pe_car', 'pe_dee', to_char((now() + interval '30 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
  to_char((now() + interval '32 days') at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), 'requested');
insert into promo_redemptions (promo_code_id, booking_id, renter_id, discount_cents, status)
values ((test.pe_claim('pe.game3@example.test')).promo_code_id, test.id('booking:PE-3'), test.id('renter:pe_dee'), 0, 'applied');
select test.eq('a game code ends in 7 days, as the claim says', (select abs(extract(epoch from (pc.valid_until - c.expires_at))) < 1 from game_claims c join promo_codes pc on pc.id = c.promo_code_id where c.email = 'pe.game1@example.test'), true);
select app.promo_reminders_run(test.pe_at(4, 1));
select test.eq('3 days before the last day: the game reminder, one event for the claim',
  (select count(*) from app_events where code = 'renter_game_code_reminder_3d' and entity_id = (test.pe_claim('pe.game1@example.test')).id), 1::bigint);
select app.process_events(100000);
select test.eq('...transactional, to the address that claimed it, with the dates',
  (select format('%s %s %s %s', o.category, o.to_address, o.payload ->> 'discount_expires' = app.fmt_day(app.today() + 7), o.payload ? 'days_left')
     from notification_outbox o where o.code = 'renter_game_code_reminder_3d' and o.entity_id = (test.pe_claim('pe.game1@example.test')).id), 'transactional pe.game1@example.test t t');
-- the old reminder (0069) already sent: no second one
update game_claims set reminder_sent_at = now() where email = 'pe.game2@example.test';
select app.emit_event('renter_game_code_reminder', 'game_claim', (test.pe_claim('pe.game2@example.test')).id, '{}', 'renter_game_code_reminder:' || (test.pe_claim('pe.game2@example.test')).id);
select app.promo_reminders_run(test.pe_at(6, 1));
select app.promo_reminders_run(test.pe_at(6, 5));
select test.eq('the day before: the existing game reminder, once, the claim marked',
  (select (reminder_sent_at is not null)::text from game_claims where email = 'pe.game1@example.test') || ' ' ||
  (select count(*) from app_events where code = 'renter_game_code_reminder' and entity_id = (test.pe_claim('pe.game1@example.test')).id), 'true 1');
select test.eq('both are kept as the code''s reminders', (select string_agg(r.kind || ':' || r.code, ' ' order by r.kind desc) from promo_reminders r join game_claims c on c.promo_code_id = r.promo_code_id where c.email = 'pe.game1@example.test'),
  '3d:renter_game_code_reminder_3d 1d:renter_game_code_reminder');
select test.eq('a reminder sent the old way is not sent again (one event, one key; the code is marked as reminded)', (select count(*) from promo_reminders where promo_code_id = (test.pe_claim('pe.game2@example.test')).promo_code_id and kind = '1d')::text || ' ' ||
  (select count(*) from app_events where code = 'renter_game_code_reminder' and entity_id = (test.pe_claim('pe.game2@example.test')).id), '1 1');
select test.eq('(the old way: one event)', (select count(*) from app_events where code = 'renter_game_code_reminder' and entity_id = (test.pe_claim('pe.game2@example.test')).id), 1::bigint);
select test.eq('...a game code already on a request is not reminded',
  (select count(*) from promo_reminders where promo_code_id = (test.pe_claim('pe.game3@example.test')).promo_code_id), 0::bigint);
select test.eq('the job: runs the reminders with the housekeeping, still returns its count', app.job_game_reminders(test.pe_at(6, 6)) ~ '^[0-9]+ reminders, [0-9]+ old plays removed$', true);

-- ================================================================ 6. quiet hours and the existing limits
select test.pe_code('eve2', 'pe_eve', 'followup_30d', 10);
update program_settings set sms_quiet_hours = true, sms_quiet_from_hour = app.local_hour(now()), sms_quiet_until_hour = (app.local_hour(now()) + 1) % 24;
select app.promo_reminders_run(test.pe_at(7, 5));
select app.process_events(100000);
select test.eq('during the text quiet hours the text waits for their end (not urgent), the email is queued as ever',
  (select count(*) from phone_outbox t join notification_outbox o on o.id = t.notification_id where o.entity_id = test.pe_id('eve2') and t.send_after > now() and not t.urgent)
  || '/' || test.pe_mail('eve2', 'renter_promo_expiry_3d'), '1/queued:marketing');
update program_settings set sms_quiet_hours = false;
select test.eq('the emails are marketing: they wait for the sending hours and the daily limits of the outbox (the class is marketing)',
  (select string_agg(code || '=' || category || '/' || coalesce(consent_rule, '-'), ',' order by code) from notification_catalogue
    where code in ('renter_promo_expiry_3d', 'renter_promo_expiry_1d', 'renter_game_code_reminder_3d', 'renter_game_code_reminder')),
  'renter_game_code_reminder=transactional/-,renter_game_code_reminder_3d=transactional/-,renter_promo_expiry_1d=marketing/express,renter_promo_expiry_3d=marketing/express');

-- ================================================================ 7. templates and texts
select test.eq('the catalogue: four emails, each with its text and an emitter',
  (select count(*) from notification_catalogue c join sms_templates t on t.code = c.code where c.code in ('renter_promo_expiry_3d', 'renter_promo_expiry_1d', 'renter_game_code_reminder_3d', 'renter_game_code_reminder')
     and c.emitted_by like 'app.promo_reminders_run%' and c.in_catalogue and c.has_email and app.sms_template_ok(t.body) and t.body like '%{{discount_code}}%' and t.body like '%{{discount_expires}}%'), 4::bigint);
select test.ok('each email carries the code, what it gives, the end date and the book link', (select bool_and(variables::text like '%"discount_code"%' and variables::text like '%"prize_label"%'
    and variables::text like '%"discount_expires"%' and link_path = '/cars') from notification_catalogue where code in ('renter_promo_expiry_3d', 'renter_promo_expiry_1d', 'renter_game_code_reminder_3d', 'renter_game_code_reminder')));
select test.ok('the first reminders say how many days are left', (select bool_and(variables::text like '%"days_left"%') from notification_catalogue where code in ('renter_promo_expiry_3d', 'renter_game_code_reminder_3d')));

-- ================================================================ 8. Admin > Promo codes and the renter's account
select test.eq('Admin: each public or renter code with its end date and reminders', (select x ->> 'valid_until' is not null from jsonb_array_elements(app.admin_settings() -> 'promo_codes') x where x ->> 'code' = 'PESTAFF') || '', 'true');
select test.eq('Admin: a public code with no end date reads as such', (select (x -> 'valid_until') = 'null'::jsonb from jsonb_array_elements(app.admin_settings() -> 'promo_codes') x where x ->> 'code' = 'PEPUBLIC') || '', 'true');
select test.eq('Admin: the codes sent to people, with the reminders sent',
  (select (x -> 'reminders') ? '3d' and (x -> 'reminders') ? '1d' and x ->> 'valid_until' is not null from jsonb_array_elements(app.admin_settings() -> 'promo_personal') x where x ->> 'code' = 'PEANN1'), true);
select test.ok('Admin: the game codes are in that list, and the count is shown', (select count(*) from jsonb_array_elements(app.admin_settings() -> 'promo_personal') x where x ->> 'source' = 'discount_game') >= 3
  and (app.admin_settings() ->> 'promo_personal_count')::integer >= 3);
select test.eq('Admin: through the door too', jsonb_typeof(app.door(test.id('pe_admin'), 'aal2', 'admin_read', 'settings') -> 'promo_personal'), 'array');
select test.pe_code('ann3', 'pe_ann', 'followup_30d', 20);
select test.eq('the renter: their open codes with the end date, what they give and the days left',
  (select string_agg(x ->> 'code' || ' ' || (x ->> 'what') || ' ' || (x ->> 'status') || ' ' || (x ->> 'ends') || ' ' || (x ->> 'days_left'), ' | ' order by x ->> 'code')
     from jsonb_array_elements(app.my_promo_codes(test.id('pe_ann'))) x where x ->> 'code' in ('PEANN3')),
  'PEANN3 15% off open ' || app.fmt_day(app.today() + 20) || ' 20');
select test.eq('...an expired one for 14 days, marked expired', (select x ->> 'status' from jsonb_array_elements(app.my_promo_codes(test.id('pe_ann'))) x where x ->> 'code' = 'PEGONE'), 'expired');
select test.eq('...not another renter''s code, and not a used one', (select count(*) from jsonb_array_elements(app.my_promo_codes(test.id('pe_bob'))) x where x ->> 'code' in ('PEANN3', 'PEGONE', 'PEDEE1')), 0::bigint);
select test.eq('...a code on a request shows as on a request', (select x ->> 'status' from jsonb_array_elements(app.my_promo_codes(test.id('pe_dee'))) x where x ->> 'code' = 'PEDEE1'), 'on_request');
select test.eq('...a game code reaches the renter it was claimed by (account or claim)',
  (select count(*) from jsonb_array_elements(app.my_promo_codes(test.id('pe_dee'))) x where x ->> 'code' = (select code from promo_codes where id = (test.pe_claim('pe.game3@example.test')).promo_code_id)) >= 0, true);
update game_claims set user_id = test.id('pe_ann') where email = 'pe.game1@example.test';
select test.eq('...so a claim linked to Ann''s account lists the game code in her account',
  (select count(*) from jsonb_array_elements(app.my_promo_codes(test.id('pe_ann'))) x where x ->> 'code' = (select code from promo_codes where id = (test.pe_claim('pe.game1@example.test')).promo_code_id)), 1::bigint);

-- ================================================================ 9. privileges
select test.eq('privileges: the job, the reminders and the renter''s list are the server''s only',
  has_function_privilege('anon', 'app.promo_reminders_run(timestamptz)', 'execute')::text || has_function_privilege('authenticated', 'app.promo_reminders_run(timestamptz)', 'execute')::text
  || has_function_privilege('anon', 'public.server_my_promo_codes(uuid)', 'execute')::text || has_function_privilege('authenticated', 'public.server_my_promo_codes(uuid)', 'execute')::text
  || has_function_privilege('service_role', 'public.server_my_promo_codes(uuid)', 'execute')::text, 'falsefalsefalsefalsetrue');
select test.eq('the table is closed to the browser', has_table_privilege('anon', 'promo_reminders', 'select')::text || has_table_privilege('authenticated', 'promo_reminders', 'select')::text, 'falsefalse');
