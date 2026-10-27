-- 99: Sales work modes (migration 0174): in person and remote on the same Sales dashboard. The mode (Admin, and the function
-- the hire flow calls), the tiers by mode (10/15/20 in person, 5/10/15 remote), the remote monthly minimum of touches and its
-- tier drop with the floor (settings), the month locked once approved (the mode at the time kept), the credit rules (remote:
-- only rentals they source; a website request answered with the first offer on their shift is theirs), the touches logged by
-- the system and by hand, the availability blocks and the peak-hour cover, the reply time, and the privileges (a rep reads
-- only their own). Fixtures start with "swm". Days are Toronto days (app.today()).
select test.suite('99 sales work modes');

select test.mk_user('swm_admin', 'admin');
select test.mk_user('swm_inp', 'va', 'sales');
select test.mk_user('swm_rem', 'va', 'sales');
select test.mk_user('swm_rem2', 'va', 'sales');
select test.mk_user('swm_cs', 'va', 'cs');
select test.mk_renter('swm_rita');
select test.mk_renter('swm_ron');
update staff_profiles set single_limit_cents = 500000 where user_id in (test.id('swm_inp'), test.id('swm_rem'), test.id('swm_rem2'));

create temp table s99w as select null::text as k, null::jsonb as v limit 0;
create or replace function test.swm(p_k text) returns jsonb language sql stable as $$ select v from pg_temp.s99w where k = p_k $$;
create or replace function test.swmb(p_k text) returns bookings language sql stable as $$
  select * from bookings where id = coalesce((test.swm(p_k) ->> 'booking_id')::uuid, (test.swm(p_k) ->> 'id')::uuid) $$;
create or replace function test.swmc(p_k text) returns staff_commissions language sql stable as $$
  select * from staff_commissions where booking_id = (test.swmb(p_k)).id and kind = 'commission' order by created_at desc limit 1 $$;
do $$
declare i integer;
begin
  for i in 1 .. 11 loop
    insert into s99w select 'car' || i, app.vehicle_add(test.id('swm_admin'), jsonb_build_object('supply_type', 'company', 'vin', '1SWMXMM00000000' || lpad(i::text, 2, '0'),
      'plate', 'SWM00' || i, 'year', 2024, 'make', 'Kia', 'model', 'K5', 'rates', jsonb_build_object('daily', 10000, 'weekend', 10000, 'weekly', 70000, 'monthly', 300000, 'deposit', 30000)));
  end loop;
end $$;
create or replace function test.swmv(p text) returns uuid language sql stable as $$ select (test.swm(p) ->> 'vehicle_id')::uuid $$;
create or replace function test.swmm() returns date language sql stable as $$ select (app.month_start(app.today()) - interval '1 month')::date $$;
create or replace function test.swmpast(p_vehicle uuid, p_day integer, p_days integer, p_source text default 'phone') returns jsonb language sql as $$
  select jsonb_build_object('vehicle_id', p_vehicle, 'pickup_at', app.local_midnight(test.swmm() + p_day - 1) + interval '10 hours',
    'return_at', app.local_midnight(test.swmm() + p_day - 1 + p_days) + interval '10 hours', 'source', p_source, 'coverage_option', 1, 'past', true,
    'renter_id', test.id('renter:swm_rita'), 'payment', jsonb_build_object('mode', 'other_way', 'method', 'cash')) $$;
create or replace function test.swmfut(p_vehicle uuid, p_from interval, p_to interval, p_source text) returns jsonb language sql as $$
  select jsonb_build_object('vehicle_id', p_vehicle, 'pickup_at', date_trunc('hour', now()) + p_from, 'return_at', date_trunc('hour', now()) + p_to,
                            'source', p_source, 'coverage_option', 1, 'renter_id', test.id('renter:swm_rita'), 'payment', jsonb_build_object('mode', 'link')) $$;
create or replace function test.swmsold(p_k text, p_staff text, p_spec jsonb) returns void language plpgsql as $$
begin
  insert into s99w select p_k, app.manual_rental_create(test.id('swm_admin'), p_spec);
  perform app.sales_reassign(test.id('swm_admin'), jsonb_build_object('booking', (test.swmb(p_k)).id, 'staff', test.id(p_staff), 'sourced', true, 'reason', 'Test: sold by ' || p_staff));
end $$;
create or replace function test.swmrate(p_staff text) returns text language sql stable as $$
  select r.work_mode || '/' || r.tier_days || '/' || r.tier_bps || '/' || r.rate_bps || '/' || r.touches || '/' || r.dropped
    from sales_month_rates r where r.staff_id = test.id(p_staff) and r.month = test.swmm() $$;

-- ================================================================ 1. settings and the mode
select test.eq('settings: remote 5/10/15%, 400 touches, one tier, floor 2.5%, 20 peak hours, 15 minutes, noon to 6 pm',
  (select s.sales_remote_tier_low_bps || '/' || s.sales_remote_tier_mid_bps || '/' || s.sales_remote_tier_high_bps || '/' || s.sales_remote_min_touches || '/' || s.sales_remote_drop_tiers
          || '/' || s.sales_remote_floor_bps || '/' || s.sales_remote_cover_hours || '/' || s.sales_remote_reply_minutes || '/' || s.sales_remote_peak_from_hour || '/' || s.sales_remote_peak_until_hour
     from (select (app.settings()).*) s), '500/1000/1500/400/1/250/20/15/12/18');
select test.eq('mode: a Sales assistant is in person until an Admin chooses; nobody else has one',
  coalesce(app.swm_mode(test.id('swm_inp')), '-') || '/' || coalesce((select sales_work_mode from staff_profiles where user_id = test.id('swm_cs')), '-') || '/' || coalesce(app.swm_mode(test.id('swm_cs')), '-'),
  'in_person/-/-');
select test.throws('mode: an Admin only', format($$select app.door(%L, 'aal2', 'admin_do', 'staff_sales_mode_set', jsonb_build_object('staff', %L, 'mode', 'remote'))$$,
  test.id('swm_inp'), test.id('swm_rem')), 'admin');
select test.throws('mode: only for Sales staff', format($$select app.staff_set_sales_mode(%L, %L, 'remote')$$, test.id('swm_admin'), test.id('swm_cs')), 'Sales staff member');
select test.throws('mode: in person or remote', format($$select app.staff_set_sales_mode(%L, %L, 'abroad')$$, test.id('swm_admin'), test.id('swm_rem')), 'in person or remote');
select test.eq('mode: set through the door', app.door(test.id('swm_admin'), 'aal2', 'admin_do', 'staff_sales_mode_set',
  jsonb_build_object('staff', test.id('swm_rem'), 'mode', 'remote', 'reason', 'Works from abroad')) ->> 'mode', 'remote');
select test.ok('mode: audited with the reason', exists (select 1 from audit_log a where a.action = 'staff_sales_mode_set' and a.entity_id = test.id('swm_rem')::text
  and a.after ->> 'sales_work_mode' = 'remote' and a.after ->> 'reason' = 'Works from abroad'));
select test.eq('mode: the hire flow''s function', app.staff_set_sales_mode(test.id('swm_admin'), test.id('swm_rem2'), 'remote', 'Hired as remote') ->> 'changed', 'true');
select test.eq('mode: setting the same mode again changes nothing', app.staff_set_sales_mode(test.id('swm_admin'), test.id('swm_rem2'), 'remote') ->> 'changed', 'false');
update staff_profiles set va_function = 'cs' where user_id = test.id('swm_rem2');
select test.eq('mode: cleared when the person leaves Sales', coalesce((select sales_work_mode from staff_profiles where user_id = test.id('swm_rem2')), 'none'), 'none');
update staff_profiles set va_function = 'sales' where user_id = test.id('swm_rem2');
select app.staff_set_sales_mode(test.id('swm_admin'), test.id('swm_rem2'), 'remote');

-- ================================================================ 2. rates by mode and tier, the minimum and the drop (last month, ended)
select test.swmsold('inp1', 'swm_inp', test.swmpast(test.swmv('car1'), 1, 20, 'walk_in'));
select test.eq('in person: a walk-in they closed earns, 10% under 50 days', test.swmrate('swm_inp'), 'in_person/20/1000/1000/0/false');
select test.eq('in person: the commission carries the mode', (test.swmc('inp1')).work_mode || '/' || (test.swmc('inp1')).rate_bps, 'in_person/1000');
select test.swmsold('inp2', 'swm_inp', test.swmpast(test.swmv('car2'), 1, 20));
select test.swmsold('inp3', 'swm_inp', test.swmpast(test.swmv('car10'), 1, 10));
select test.eq('in person: 50 days, 15%; no minimum of touches', test.swmrate('swm_inp'), 'in_person/50/1500/1500/0/false');

select test.swmsold('r20', 'swm_rem', test.swmpast(test.swmv('car3'), 1, 20));
select test.eq('remote: 20 days is the 5% tier; the month ended under 400 touches: below the lowest tier, the floor 2.5%', test.swmrate('swm_rem'), 'remote/20/500/250/0/true');
select test.eq('remote: the commission at 2.5%, marked remote', (select c.rate_bps || '/' || c.work_mode || '/' || (c.amount_cents = round(c.base_cents * 0.025)) from test.swmc('r20') c), '250/remote/true');
insert into sales_touches (staff_id, at, kind, source)
select test.id('swm_rem'), app.local_midnight(test.swmm()) + interval '9 hours' + n * interval '1 minute', 'follow_up', 'manual' from generate_series(1, 400) n;
select app.commission_retier(test.id('swm_rem'), test.swmm());
select test.eq('remote: 400 touches meet the minimum: 5%', test.swmrate('swm_rem'), 'remote/20/500/500/400/false');
select test.swmsold('r20b', 'swm_rem', test.swmpast(test.swmv('car4'), 1, 20));
select test.swmsold('r10', 'swm_rem', test.swmpast(test.swmv('car11'), 1, 10));
select test.eq('remote: 50 days, 10% (5 points under in person)', test.swmrate('swm_rem'), 'remote/50/1000/1000/400/false');
select test.throws('void a touch: an Admin only', format($$select app.door(%L, 'aal2', 'admin_do', 'sales_touch_void', jsonb_build_object('id', %L, 'reason', 'x'))$$,
  test.id('swm_rem'), (select id from sales_touches where staff_id = test.id('swm_rem') order by at limit 1)), 'admin');
select test.throws('void a touch: a reason', format($$select app.door(%L, 'aal2', 'admin_do', 'sales_touch_void', jsonb_build_object('id', %L))$$,
  test.id('swm_admin'), (select id from sales_touches where staff_id = test.id('swm_rem') order by at limit 1)), 'Say why');
select app.door(test.id('swm_admin'), 'aal2', 'admin_do', 'sales_touch_void',
  jsonb_build_object('id', (select id from sales_touches where staff_id = test.id('swm_rem') order by at limit 1), 'reason', 'Logged twice'));
select test.eq('remote: 399 touches, under the minimum: the month drops one tier, 10% to 5%', test.swmrate('swm_rem'), 'remote/50/1000/500/399/true');
select test.ok('remote: every commission of the month at 5%', (select bool_and(rate_bps = 500 and amount_cents = round(base_cents * 0.05)) from staff_commissions
  where staff_id = test.id('swm_rem') and month = test.swmm() and kind = 'commission'));
update program_settings set sales_remote_drop_tiers = 2;
select app.commission_retier(test.id('swm_rem'), test.swmm());
select test.eq('setting: a drop of two tiers from 10% goes below the lowest tier: the floor 2.5%', test.swmrate('swm_rem'), 'remote/50/1000/250/399/true');
update program_settings set sales_remote_drop_tiers = 1, sales_remote_min_touches = 399;
select app.commission_retier(test.id('swm_rem'), test.swmm());
select test.eq('setting: a minimum of 399 is met', test.swmrate('swm_rem'), 'remote/50/1000/1000/399/false');
update program_settings set sales_remote_min_touches = 400;
select app.commission_retier(test.id('swm_rem'), test.swmm());
select test.eq('back to the defaults: 5%', test.swmrate('swm_rem'), 'remote/50/1000/500/399/true');
select test.ok('statement: a clear line for the drop', (app.staff_commissions_json(test.id('swm_rem')) -> 'months' -> 0 ->> 'line')
  like '%, remote: 50 rental days reach 10%, but 399 of the 400 touches were logged: the month''s rate is one tier lower, 5%.', app.staff_commissions_json(test.id('swm_rem')) -> 'months' -> 0 ->> 'line');
select test.ok('statement: the in person line', (app.staff_commissions_json(test.id('swm_inp')) -> 'months' -> 0 ->> 'line') like '%, in person: 50 rental days, 15%.');

-- ================================================================ 3. the month locked once approved
select app.commission_approve(test.id('swm_admin'), jsonb_build_object('staff', test.id('swm_rem'), 'month', test.swmm()));
select test.eq('approved: the month''s schedule is locked', (select (locked_at is not null) || '/' || (locked_by = test.id('swm_admin')) || '/' || work_mode || '/' || rate_bps
  from sales_month_rates where staff_id = test.id('swm_rem') and month = test.swmm()), 'true/true/remote/500');
update program_settings set sales_remote_tier_low_bps = 700, sales_remote_min_touches = 100;
select app.commission_retier(test.id('swm_rem'), test.swmm());
select test.eq('locked: a later change of the settings does not change the month', test.swmrate('swm_rem') || '/' || (select tier_low_bps || '/' || min_touches from sales_month_rates where staff_id = test.id('swm_rem') and month = test.swmm()),
  'remote/50/1000/500/399/true/500/400');
update program_settings set sales_remote_tier_low_bps = 500, sales_remote_min_touches = 400;
select test.throws('locked: a touch of that month can no longer be voided', format($$select app.door(%L, 'aal2', 'admin_do', 'sales_touch_void', jsonb_build_object('id', %L, 'reason', 'Late'))$$,
  test.id('swm_admin'), (select id from sales_touches where staff_id = test.id('swm_rem') and voided_at is null order by at limit 1)), 'approved');
select app.staff_set_sales_mode(test.id('swm_admin'), test.id('swm_rem'), 'in_person', 'Moved to Toronto');
select test.eq('locked: switching to in person keeps the month remote at 5%; history shows the mode at the time',
  test.swmrate('swm_rem') || '/' || (select string_agg(distinct work_mode || ':' || rate_bps, ',') from staff_commissions where staff_id = test.id('swm_rem') and month = test.swmm() and kind = 'commission')
  || '/' || (app.staff_commissions_json(test.id('swm_rem')) -> 'months' -> 0 ->> 'work_mode') || '/' || (app.staff_commissions_json(test.id('swm_rem')) ->> 'mode'),
  'remote/50/1000/500/399/true/remote:500/remote/in_person');
select test.ok('commission rows carry the mode on My sales', (select bool_and(e ->> 'work_mode' = 'remote') from jsonb_array_elements(app.staff_commissions_json(test.id('swm_rem')) -> 'rows') e
  where e ->> 'month' = test.swmm()::text));
select app.staff_set_sales_mode(test.id('swm_admin'), test.id('swm_rem'), 'remote', 'Back abroad');

-- ================================================================ 4. credit: remote earns only on rentals they source
select test.swmsold('rwalk', 'swm_rem', test.swmfut(test.swmv('car5'), interval '3 days', interval '5 days', 'walk_in'));
select test.swmsold('rpart', 'swm_rem', test.swmfut(test.swmv('car6'), interval '3 days', interval '5 days', 'partner'));
select test.swmsold('rphone', 'swm_rem', test.swmfut(test.swmv('car7'), interval '3 days', interval '5 days', 'phone'));
select test.eq('remote: a walk-in and a partner deal earn nothing; a rental they sourced by phone accrues',
  (select count(*) from staff_commissions c where c.booking_id in ((test.swmb('rwalk')).id, (test.swmb('rpart')).id) and c.status not in ('void', 'reversed'))
  || '/' || (test.swmc('rphone')).status || '/' || (test.swmc('rphone')).work_mode, '0/accruing/remote');
select test.eq('the reason in words', app.commission_own_reason((test.swmb('rwalk')).id, test.id('swm_rem')), 'Remote sales: a walk-in or a partner deal earns no commission');
select test.swmsold('iwalk', 'swm_inp', test.swmfut(test.swmv('car8'), interval '3 days', interval '5 days', 'walk_in'));
select test.eq('in person: the same walk-in accrues', (test.swmc('iwalk')).status || '/' || (test.swmc('iwalk')).work_mode, 'accruing/in_person');
select app.staff_set_sales_mode(test.id('swm_admin'), test.id('swm_rem'), 'in_person');
select test.eq('switching to in person: the open month''s walk-in now accrues', (test.swmc('rwalk')).status, 'accruing');
select app.staff_set_sales_mode(test.id('swm_admin'), test.id('swm_rem'), 'remote');
select test.eq('and back to remote: it stops, with the reason', (test.swmc('rwalk')).status || '/' || (test.swmc('rwalk')).reason, 'void/Remote sales: a walk-in or a partner deal earns no commission');

-- availability: the rep's blocks (today, through the door; yesterday as a fixture so a late-evening run still has its shift)
select test.throws('availability: remote staff only', format($$select app.door(%L, 'aal2', 'va_do', 'sales_availability_save', jsonb_build_object('week', app.today(), 'blocks', '[]'::jsonb))$$,
  test.id('swm_inp')), 'remote Sales');
select test.lives('availability: today, all day', format($$select app.door(%L, 'aal2', 'va_do', 'sales_availability_save', jsonb_build_object('week', app.today(),
  'blocks', jsonb_build_array(jsonb_build_object('day', app.today(), 'from', '00:00', 'to', '24:00'))))$$, test.id('swm_rem')));
insert into sales_availability (staff_id, day, from_minute, until_minute) values (test.id('swm_rem'), app.today() - 1, 0, 1440);
select test.eq('on shift now', app.swm_on_shift(test.id('swm_rem'), now()) || '/' || app.swm_on_shift(test.id('swm_rem2'), now()), 'true/false');

-- a website request answered with the first offer on the shift is theirs, even marked "Entered for CarmaCars"
insert into s99w select 'web1', jsonb_build_object('id', app.request_booking(test.id('renter:swm_ron'), test.swmv('car9'), date_trunc('hour', now()) + interval '40 days',
  date_trunc('hour', now()) + interval '43 days', 'standard', null, 'web', test.id('swm_ron')));
select app.door(test.id('swm_rem'), 'aal2', 'va_do', 'send_offer', jsonb_build_object('booking', (test.swmb('web1')).id, 'expires_at', now() + interval '24 hours', 'sales_choice', 'for_carmacars'));
select test.eq('website request on shift: credited to the remote rep as sourced, a commission accruing',
  (select (sales_staff_id = test.id('swm_rem')) || '/' || sales_sourced || '/' || sales_choice || '/' || (sales_claim_by is null) from test.swmb('web1')) || '/' || (test.swmc('web1')).status,
  'true/true/sourced/true/accruing');
select test.ok('website request on shift: a line in the booking''s history', exists (select 1 from booking_events e where e.booking_id = (test.swmb('web1')).id and e.kind = 'sales_credit'
  and e.note like 'Website request answered on a remote shift by%'));
insert into s99w select 'web2', jsonb_build_object('id', app.request_booking(test.id('renter:swm_ron'), test.swmv('car9'), date_trunc('hour', now()) + interval '50 days',
  date_trunc('hour', now()) + interval '53 days', 'standard', null, 'web', test.id('swm_ron')));
select app.door(test.id('swm_rem2'), 'aal2', 'va_do', 'send_offer', jsonb_build_object('booking', (test.swmb('web2')).id, 'expires_at', now() + interval '24 hours', 'sales_choice', 'sourced'));
select test.eq('website request off shift: a claim for an Admin, as before', (select sales_sourced || '/' || (sales_claim_by = test.id('swm_rem2')) from test.swmb('web2')), 'false/true');

-- ================================================================ 5. touches the system logs, and by hand
select test.eq('offer sent: a follow-up touch on the booking', (select count(*) || '/' || min(kind) || '/' || min(source) from sales_touches
  where staff_id = test.id('swm_rem') and booking_id = (test.swmb('web1')).id), '1/follow_up/offer');
insert into messages (direction, channel, subject, body, renter_id, booking_id, sent_by, status)
values ('outbound', 'portal', 'Your booking', 'Following up on your offer', test.id('renter:swm_ron'), (test.swmb('web1')).id, test.id('swm_rem'), 'delivered');
insert into messages (direction, channel, body, related_table, related_id, sent_by, status) values ('outbound', 'portal', 'Internal note', 'tasks', gen_random_uuid(), test.id('swm_rem'), 'delivered');
select test.eq('portal message: a follow-up touch; an internal task note is not one', (select count(*) from sales_touches where staff_id = test.id('swm_rem') and source = 'message'), 1::bigint);
insert into chat_conversations (id, assigned_to, status, human_requested_at, first_human_reply_at)
values (test.id('swm_chat1'), test.id('swm_rem'), 'human', now() - interval '20 minutes', now() - interval '10 minutes');
insert into chat_messages (conversation_id, sender, staff_id, body) values (test.id('swm_chat1'), 'staff', test.id('swm_rem'), 'Hi, how can I help?'), (test.id('swm_chat1'), 'staff', test.id('swm_rem'), 'The K5 is free.');
select test.eq('live chat answered: one DM reply touch a conversation a day', (select count(*) from sales_touches where staff_id = test.id('swm_rem') and kind = 'dm_reply'), 1::bigint);
insert into phone_threads (id, number) values (test.id('swm_thread'), '+14165550987');
insert into phone_activity (thread_id, kind, direction, body, sent_by) values (test.id('swm_thread'), 'text', 'out', 'Following up on the long-term quote', test.id('swm_rem'));
select test.eq('a text from the phone line: an outreach text', (select count(*) from sales_touches where staff_id = test.id('swm_rem') and kind = 'outreach_text' and source = 'phone'), 1::bigint);
select test.throws('log a touch: remote staff only', format($$select app.door(%L, 'aal2', 'va_do', 'sales_touch_log', '{"kind": "repost"}')$$, test.id('swm_inp')), 'remote Sales');
select test.throws('log a touch: a type', format($$select app.door(%L, 'aal2', 'va_do', 'sales_touch_log', '{"kind": "lunch"}')$$, test.id('swm_rem')), 'type of touch');
select test.throws('log a touch: a real link', format($$select app.door(%L, 'aal2', 'va_do', 'sales_touch_log', '{"kind": "repost", "link": "ftp://x y"}')$$, test.id('swm_rem')), 'https://');
insert into s99w select 'log1', app.door(test.id('swm_rem'), 'aal2', 'va_do', 'sales_touch_log', '{"kind": "repost", "link": "https://www.facebook.com/marketplace/item/123"}');
select test.eq('log a touch: a repost with its link counts toward the month', (test.swm('log1') ->> 'touches')::integer, app.swm_touch_count(test.id('swm_rem'), app.month_start(app.today())));
select test.eq('log a touch: kept with its link', (select kind || '/' || source || '/' || link from sales_touches where id = (test.swm('log1') ->> 'id')::uuid), 'repost/manual/https://www.facebook.com/marketplace/item/123');

-- ================================================================ 6. the dashboard: checklist, cover, replies, progress
select test.ok('checklist: the repost and the DM reply are done today; the quote follow-ups and outreach are counted',
  (select bool_and(case e ->> 'key' when 'repost' then (e ->> 'count')::int >= 1 when 'dm_reply' then (e ->> 'count')::int >= 1 when 'follow_up' then (e ->> 'count')::int >= 2
                     when 'outreach' then (e ->> 'count')::int >= 1 end) and count(*) = 4
     from jsonb_array_elements(app.swm_duties(test.id('swm_rem')) -> 'checklist') e));
select test.eq('checklist: the open deals with fewer than three follow-ups', (select (e ->> 'open_quotes')::int from jsonb_array_elements(app.swm_duties(test.id('swm_rem')) -> 'checklist') e where e ->> 'key' = 'follow_up'), 4);
select test.throws('availability: blocks may not overlap', format($$select app.door(%L, 'aal2', 'va_do', 'sales_availability_save', jsonb_build_object('week', app.today() + 7,
  'blocks', jsonb_build_array(jsonb_build_object('day', date_trunc('week', app.today())::date + 10, 'from', '12:00', 'to', '18:00'),
                              jsonb_build_object('day', date_trunc('week', app.today())::date + 10, 'from', '17:00', 'to', '19:00'))))$$, test.id('swm_rem')), 'overlap');
select test.throws('availability: a past day cannot change', format($$select app.door(%L, 'aal2', 'va_do', 'sales_availability_save', jsonb_build_object('week', app.today() - 1,
  'blocks', jsonb_build_array(jsonb_build_object('day', app.today() - 1, 'from', '12:00', 'to', '18:00'))))$$, test.id('swm_rem')), 'past');
select test.eq('availability: next Thursday noon to 6 pm and Saturday 10 to 2 is 8 peak hours',
  (app.door(test.id('swm_rem'), 'aal2', 'va_do', 'sales_availability_save', jsonb_build_object('week', app.today() + 7,
    'blocks', jsonb_build_array(jsonb_build_object('day', date_trunc('week', app.today())::date + 10, 'from', '12:00', 'to', '18:00'),
                                jsonb_build_object('day', date_trunc('week', app.today())::date + 12, 'from', '10:00', 'to', '14:00')))) ->> 'peak_hours')::numeric, 8.0);
select test.eq('availability: shown as next week on the dashboard', (app.swm_duties(test.id('swm_rem')) -> 'next_week' ->> 'peak_hours')::numeric, 8.0);
insert into tasks (queue, task_type, title, assigned_to, status, created_at, completed_at, completed_by)
values ('sales', 'renter_message', 'swm late reply', test.id('swm_rem'), 'done', now() - interval '30 minutes', now(), test.id('swm_rem')),
       ('sales', 'renter_message', 'swm not theirs', test.id('swm_rem2'), 'done', now() - interval '30 minutes', now(), test.id('swm_rem2'));
select test.eq('reply time: the chat answered in 10 minutes is within 15; the message after 30 is not',
  (select (r ->> 'count') || '/' || (r ->> 'within') || '/' || (r ->> 'target_minutes') from (select app.swm_duties(test.id('swm_rem')) -> 'replies_month' r) x), '2/1/15');
select test.eq('reply time: nothing measured off shift', (app.swm_replies(test.id('swm_rem2'), now() - interval '1 day', now() + interval '1 minute') ->> 'count')::int, 0);
select test.eq('this month, remote: the tier rate until the month ends, the drop projected while under the minimum',
  (select (p ->> 'mode') || '/' || (p ->> 'below_minimum') || '/' || (p ->> 'closed') || '/' || (p ->> 'rate_bps') || '/' || (p ->> 'projected_bps')
     from (select app.sales_month_progress(test.id('swm_rem')) p) x), 'remote/true/false/500/250');
select test.eq('in person: no remote duties on the dashboard', (select (d ->> 'mode') || '/' || (d ? 'checklist') || '/' || (d -> 'progress' ->> 'mode') from (select app.swm_duties(test.id('swm_inp')) d) x),
  'in_person/false/in_person');

-- ================================================================ 7. privileges: a rep sees only their own
select test.eq('va_read sales_duties: always the person''s own', (app.door(test.id('swm_inp'), 'aal2', 'va_read', 'sales_duties', jsonb_build_object('staff', test.id('swm_rem'))) ->> 'mode'), 'in_person');
select test.throws('admin_read sales_duties: Admins only', format($$select app.door(%L, 'aal2', 'admin_read', 'sales_duties', jsonb_build_object('staff', %L))$$, test.id('swm_rem'), test.id('swm_inp')), 'admin');
select test.throws('admin_read sales_modes: Admins only', format($$select app.door(%L, 'aal2', 'admin_read', 'sales_modes', '{}')$$, test.id('swm_rem')), 'admin');
select test.eq('Admin: the staff list with mode, touches and the projected rate',
  (select (e ->> 'mode') || '/' || ((e ->> 'touches')::int = app.swm_touch_count(test.id('swm_rem'), app.month_start(app.today()))) || '/' || (e -> 'progress' ->> 'projected_bps')
     from jsonb_array_elements(app.door(test.id('swm_admin'), 'aal2', 'admin_read', 'sales_modes', '{}') -> 'people') e where (e ->> 'id')::uuid = test.id('swm_rem')), 'remote/true/250');
select test.eq('Admin: one rep''s duties', app.door(test.id('swm_admin'), 'aal2', 'admin_read', 'sales_duties', jsonb_build_object('staff', test.id('swm_rem'))) ->> 'mode', 'remote');
select set_config('request.jwt.claim.sub', test.id('swm_inp')::text, false);
set role authenticated;
select test.eq('row security: a rep reads their own touches, month rates and blocks, nobody else''s',
  (select count(*) from sales_touches where staff_id <> test.id('swm_inp')) || '/' || (select count(*) from sales_month_rates where staff_id <> test.id('swm_inp'))
  || '/' || (select count(*) from sales_availability where staff_id <> test.id('swm_inp')) || '/' || ((select count(*) from sales_month_rates where staff_id = test.id('swm_inp')) > 0), '0/0/0/true');
select test.throws('row security: a browser session writes no touch', $$insert into sales_touches (staff_id, kind, source) values (app.uid(), 'repost', 'manual')$$);
reset role;
select set_config('request.jwt.claim.sub', '', false);
select test.ok('new functions: not callable from a browser', not has_function_privilege('authenticated', 'app.staff_set_sales_mode(uuid, uuid, text, text)', 'execute')
  and not has_function_privilege('authenticated', 'app.swm_duties(uuid)', 'execute') and not has_function_privilege('anon', 'app.sales_touch_log(uuid, jsonb)', 'execute'));
