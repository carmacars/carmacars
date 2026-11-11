-- 99: the field shift picker (migration 1770, release 35, part SP, docs/changes/2026-11-11-r35-shift-picker.md): availability
-- (an onboarding step), standing weekly shifts, the minimum and its nag, unclaimed slot alerts with suggestions, the board's
-- counts, and the role checks. Fixtures "r35sp"; example.test only.
select test.suite('99 r35sp shift picker');
grant usage on schema test to service_role;

update program_settings set field_jobs_auto = false, field_jobs_auto_assign = 'none', academy_gate = true,
  field_min_shifts_week = 2, field_claim_ahead_days = 7, field_unclaimed_alert_hours = 48, field_standing_ahead_days = 14;
select test.mk_user('r35sp_admin', 'admin');
select test.mk_user('r35sp_fleet', 'va', 'fleet');
select test.mk_user('r35sp_cs', 'va', 'cs');
select test.mk_user('r35sp_a', 'field');
select test.mk_user('r35sp_b', 'field');
select test.mk_user('r35sp_c', 'field');
select test.mk_user('r35sp_d', 'field');
select test.mk_user('r35sp_e', 'field');
select test.mk_user('r35sp_f', 'field');
select test.mk_user('r35sp_new', 'field');
update users set phone = '+14165550142' where id = test.id('r35sp_a');
-- d is held by the academy (a new hire)
select app.academy_enroll(test.id('r35sp_d'), test.id('r35sp_admin'), 'hire', now());

create function test.r35sp_fd(p_who text, p_name text, p jsonb default '{}') returns jsonb language sql as $$ select public.door(test.id(p_who), null, 'field_do', p_name, p) $$;
create function test.r35sp_fr(p_who text, p_name text, p jsonb default '{}') returns jsonb language sql as $$ select public.door(test.id(p_who), null, 'field_read', p_name, p) $$;
create function test.r35sp_op(p_who text, p_name text, p jsonb default '{}') returns jsonb language sql as $$ select public.door(test.id(p_who), null, 'ops_do', p_name, p) $$;
create function test.r35sp_or(p_who text, p_name text, p jsonb default '{}') returns jsonb language sql as $$ select public.door(test.id(p_who), null, 'ops_read', p_name, p) $$;
-- a local Toronto time p_days from today
create function test.r35sp_at(p_days integer, p_hour integer) returns timestamptz language sql as $$
  select ((app.today() + p_days)::timestamp + make_interval(hours => p_hour)) at time zone 'America/Toronto' $$;
create function test.r35sp_slot(p_days integer, p_from integer, p_to integer) returns uuid language sql as $$
  select id from field_shift_slots where cancelled_at is null and starts_at = test.r35sp_at(p_days, p_from) and ends_at = test.r35sp_at(p_days, p_to) order by created_at desc limit 1 $$;
create function test.r35sp_holds(p_who text, p_slot uuid) returns boolean language sql as $$
  select exists (select 1 from field_shift_plans x where x.staff_id = test.id(p_who) and x.slot_id = p_slot and x.cancelled_at is null) $$;

-- ================================================================ 1. availability
select test.eq('parts: Saturday 10 to 6 is the morning and the afternoon (an hour of the evening is not counted)',
  app.fx_parts('2026-11-14 10:00 America/Toronto', '2026-11-14 18:00 America/Toronto'), array['6:am', '6:pm']);
select test.eq('parts: a short shift across noon counts both halves', app.fx_parts('2026-11-14 11:00 America/Toronto', '2026-11-14 13:00 America/Toronto'), array['6:am', '6:pm']);
select test.eq('parts: an evening', app.fx_parts('2026-11-16 18:00 America/Toronto', '2026-11-16 22:00 America/Toronto'), array['1:eve']);
select test.eq('parts: a night shift covers no part of the grid', app.fx_parts('2026-11-16 23:30 America/Toronto', '2026-11-17 05:00 America/Toronto'), '{}'::text[]);
select test.eq('the grid has 21 cells', cardinality(app.fx_avail_keys()), 21);
select test.throws('availability: customer service is not field staff', $$select test.r35sp_op('r35sp_cs', 'availability_save', jsonb_build_object('slots', jsonb_build_array('1:am')))$$, 'Only field staff');
select test.throws('availability: at least one time', $$select test.r35sp_fd('r35sp_a', 'availability_save', jsonb_build_object('slots', '[]'::jsonb))$$, 'at least one');
select test.throws('availability: only cells of the grid', $$select test.r35sp_fd('r35sp_a', 'availability_save', jsonb_build_object('slots', jsonb_build_array('8:am')))$$, 'not a time');
select test.eq('availability: no direct write from the browser (read own only)', has_table_privilege('authenticated', 'field_availability', 'insert')::text || '/' || has_table_privilege('authenticated', 'field_availability', 'update')::text, 'false/false');
-- everyone in the field: free every time but f (only Monday mornings) and c (weekends)
select test.eq('availability: saved and read back', (test.r35sp_fd('r35sp_a', 'availability_save', jsonb_build_object('slots', to_jsonb(app.fx_avail_keys()), 'note', 'No Sundays before noon in winter')) ->> 'set')::boolean, true);
select test.r35sp_fd(w, 'availability_save', jsonb_build_object('slots', to_jsonb(app.fx_avail_keys()))) from unnest(array['r35sp_b', 'r35sp_d', 'r35sp_e']) w;
select test.r35sp_fd('r35sp_c', 'availability_save', jsonb_build_object('slots', jsonb_build_array('6:am', '6:pm', '6:eve', '7:am', '7:pm', '7:eve')));
select test.r35sp_fd('r35sp_f', 'availability_save', jsonb_build_object('slots', jsonb_build_array('1:am')));
select test.eq('availability: my_availability reads it with the note', test.r35sp_fr('r35sp_a', 'my_availability') ->> 'note', 'No Sundays before noon in winter');
select test.eq('availability: by the grid, f is free Monday morning only', app.fx_available(test.id('r35sp_f'), '2026-11-16 08:00 America/Toronto', '2026-11-16 11:00 America/Toronto')::text
  || '/' || app.fx_available(test.id('r35sp_f'), '2026-11-16 10:00 America/Toronto', '2026-11-16 16:00 America/Toronto')::text, 'true/false');

-- the onboarding step: a new field person with every step before it done is held until they give it
update program_settings set academy_gate = false;
update staff_profiles set onboarding_exempt = false, agreement_waived_at = now(), whatsapp_joined = app.staff_required_groups(functions), onboarding_approved_at = now()
 where user_id = test.id('r35sp_new');
select app.staff_onboarding_refresh(test.id('r35sp_new'));
select test.eq('onboarding: the next step is availability', app.staff_onboarding_state(test.id('r35sp_new')) ->> 'step', 'availability');
select test.eq('onboarding: held until it is given', app.staff_fully_onboarded(test.id('r35sp_new')), false);
select test.throws('onboarding: held, My shifts is closed', $$select test.r35sp_fr('r35sp_new', 'my_shifts')$$, 'Finish your onboarding');
select test.eq('onboarding: Welcome shows the step after the profile, open', (select (x ->> 'open') || '/' || (x ->> 'done') from jsonb_array_elements(app.staff_welcome(test.id('r35sp_new')) -> 'steps') x where x ->> 'key' = 'availability'), 'true/false');
select test.eq('onboarding: my_roles says where they are', app.my_roles(test.id('r35sp_new')) ->> 'onboarding_step', 'availability');
select test.eq('onboarding: held, the person can still give it', (test.r35sp_fd('r35sp_new', 'availability_save', jsonb_build_object('slots', jsonb_build_array('2:am', '2:pm'))) ->> 'onboarded')::boolean, true);
select test.eq('onboarding: done once it is in', app.staff_onboarding_state(test.id('r35sp_new')) ->> 'step', 'done');
select test.eq('onboarding: Welcome marks it done', (select x ->> 'done' from jsonb_array_elements(app.staff_welcome(test.id('r35sp_new')) -> 'steps') x where x ->> 'key' = 'availability'), 'true');
select test.eq('onboarding: Fleet staff have no availability step', (select count(*) from jsonb_array_elements(app.staff_welcome(test.id('r35sp_fleet')) -> 'steps') x where x ->> 'key' = 'availability'), 0::bigint);
-- a field person onboarded before the release is not held by it
update staff_profiles set availability_grandfathered = true where user_id = test.id('r35sp_new');
delete from field_availability where user_id = test.id('r35sp_new');
select test.eq('onboarding: a field person onboarded before the release is not held without it', (app.staff_onboarding_state(test.id('r35sp_new')) ->> 'availability')::boolean, true);
update program_settings set academy_gate = true;
update staff_profiles set onboarding_exempt = true where user_id = test.id('r35sp_new');

-- ================================================================ 2. standing weekly shifts
-- D: three days from today; a, c and d (held by the academy) stand on D's weekday, 10 to 6
create temp table r35sp_d as select extract(isodow from app.today() + 3)::int as dow;
grant select on r35sp_d to public;
select test.throws('standing: the end after the start', $$select test.r35sp_fd('r35sp_a', 'standing_add', jsonb_build_object('weekday', 1, 'start', '18:00', 'end', '10:00'))$$, 'end after it starts');
select test.throws('standing: a day of the week', $$select test.r35sp_fd('r35sp_a', 'standing_add', jsonb_build_object('weekday', 9, 'start', '10:00', 'end', '18:00'))$$, 'day of the week');
select test.eq('standing: a adds every D-weekday 10 to 6', (test.r35sp_fd('r35sp_a', 'standing_add', jsonb_build_object('weekday', (select dow from r35sp_d), 'start', '10:00', 'end', '18:00')) ->> 'claimed')::int, 0);
select test.throws('standing: an overlapping standing shift the same day is refused', $$select test.r35sp_fd('r35sp_a', 'standing_add', jsonb_build_object('weekday', (select dow from r35sp_d), 'start', '12:00', 'end', '20:00'))$$, 'overlaps');
select test.r35sp_fd('r35sp_c', 'standing_add', jsonb_build_object('weekday', (select dow from r35sp_d), 'start', '10:00', 'end', '18:00'));
select test.eq('standing: a person held by the academy may set one; it claims nothing while held',
  (test.r35sp_fd('r35sp_d', 'standing_add', jsonb_build_object('weekday', (select dow from r35sp_d), 'start', '10:00', 'end', '18:00')) ->> 'locked')::boolean, true);
select test.throws('standing: customer service cannot set one for someone', format($$select test.r35sp_op('r35sp_cs', 'field_standing_add', jsonb_build_object('staff', %L, 'weekday', 1, 'start', '09:00', 'end', '17:00'))$$, test.id('r35sp_b')), 'Not permitted');
select test.throws('standing: a field person cannot use the Fleet action', format($$select test.r35sp_op('r35sp_a', 'field_standing_add', jsonb_build_object('staff', %L, 'weekday', 1, 'start', '09:00', 'end', '17:00'))$$, test.id('r35sp_b')), 'Not permitted');

-- Fleet publishes D (one place): the first standing shift takes it
select test.r35sp_op('r35sp_fleet', 'field_slot_publish', jsonb_build_object('starts_at', test.r35sp_at(3, 10), 'ends_at', test.r35sp_at(3, 18), 'capacity', 1));
select test.eq('standing: publishing D claims it for the first standing person', test.r35sp_holds('r35sp_a', test.r35sp_slot(3, 10, 18)), true);
select test.eq('standing: the claimed shift is marked as standing', (select standing_id is not null from field_shift_plans where slot_id = test.r35sp_slot(3, 10, 18) and cancelled_at is null), true);
select test.eq('standing: capacity decides (c is not on the full slot)', test.r35sp_holds('r35sp_c', test.r35sp_slot(3, 10, 18)), false);
-- D + 7, two places: a and c; never d (the academy)
select test.r35sp_op('r35sp_fleet', 'field_slot_publish', jsonb_build_object('starts_at', test.r35sp_at(10, 10), 'ends_at', test.r35sp_at(10, 18), 'capacity', 2));
select test.eq('standing: D+7 (two places) goes to a and c', test.r35sp_holds('r35sp_a', test.r35sp_slot(10, 10, 18))::text || '/' || test.r35sp_holds('r35sp_c', test.r35sp_slot(10, 10, 18))::text, 'true/true');
select test.eq('standing: the academy gate still holds d', (select count(*) from field_shift_plans where staff_id = test.id('r35sp_d')), 0::bigint);
-- different hours on D's weekday are not the standing shift
select test.r35sp_op('r35sp_fleet', 'field_slot_publish', jsonb_build_object('starts_at', test.r35sp_at(10, 18), 'ends_at', test.r35sp_at(10, 22), 'capacity', 3));
select test.eq('standing: other hours that day are not claimed', (select count(*) from field_shift_plans where slot_id = test.r35sp_slot(10, 18, 22)), 0::bigint);
-- D + 14 is beyond the 14 days: not yet; a drops that date before it is claimed
select test.r35sp_op('r35sp_fleet', 'field_slot_publish', jsonb_build_object('starts_at', test.r35sp_at(17, 10), 'ends_at', test.r35sp_at(17, 18), 'capacity', 1));
select test.eq('standing: a slot beyond field_standing_ahead_days waits', (select count(*) from field_shift_plans where slot_id = test.r35sp_slot(17, 10, 18)), 0::bigint);
select test.throws('skip: the reason is required', format($$select test.r35sp_fd('r35sp_a', 'standing_skip', jsonb_build_object('id', %L, 'day', %L))$$,
  (select id from field_standing_shifts where staff_id = test.id('r35sp_a')), app.today() + 17), 'Say why');
select test.throws('skip: only a date of the standing shift', format($$select test.r35sp_fd('r35sp_a', 'standing_skip', jsonb_build_object('id', %L, 'day', %L, 'reason', 'Away'))$$,
  (select id from field_standing_shifts where staff_id = test.id('r35sp_a')), app.today() + 16), 'one of the dates');
select test.throws('skip: not someone else''s', format($$select test.r35sp_fd('r35sp_b', 'standing_skip', jsonb_build_object('id', %L, 'day', %L, 'reason', 'Away'))$$,
  (select id from field_standing_shifts where staff_id = test.id('r35sp_a')), app.today() + 17), 'not yours');
select test.eq('skip: a date not claimed yet is dropped', (test.r35sp_fd('r35sp_a', 'standing_skip', jsonb_build_object('id', (select id from field_standing_shifts where staff_id = test.id('r35sp_a')),
  'day', app.today() + 17, 'reason', 'Family wedding')) ->> 'was_claimed')::boolean, false);
select app.fx_standing_fill(null, null, now() + interval '4 days');
select test.eq('standing: once within the days ahead, D+14 goes to c (a dropped it)', test.r35sp_holds('r35sp_a', test.r35sp_slot(17, 10, 18))::text || '/' || test.r35sp_holds('r35sp_c', test.r35sp_slot(17, 10, 18))::text, 'false/true');
-- a gives D up: the 0931 rules (an offer to the others), and the standing shift never takes it back; c's does
create temp table r35sp_skip as select test.r35sp_fd('r35sp_a', 'standing_skip', jsonb_build_object('id', (select id from field_standing_shifts where staff_id = test.id('r35sp_a')),
  'day', app.today() + 3, 'reason', 'Exam that day')) as r;
grant select on r35sp_skip to public;
select test.eq('skip: a claimed date is given up with its offer', (select (r ->> 'was_claimed') || '/' || ((r ->> 'offer') is not null)::text from r35sp_skip), 'true/true');
select test.eq('skip: the give-up keeps its reason', (select cancel_reason from field_shift_plans where staff_id = test.id('r35sp_a') and slot_id = test.r35sp_slot(3, 10, 18)), 'Exam that day');
select test.throws('skip: the same date twice', format($$select test.r35sp_fd('r35sp_a', 'standing_skip', jsonb_build_object('id', %L, 'day', %L, 'reason', 'Again'))$$,
  (select id from field_standing_shifts where staff_id = test.id('r35sp_a')), app.today() + 3), 'already dropped');
select app.job_field_shift_plan();
select test.eq('standing: the hourly run gives the freed D to c, never back to a', test.r35sp_holds('r35sp_a', test.r35sp_slot(3, 10, 18))::text || '/' || test.r35sp_holds('r35sp_c', test.r35sp_slot(3, 10, 18))::text, 'false/true');
select test.eq('standing: the offer is closed as claimed by c', (select status || '/' || (claimed_by = test.id('r35sp_c'))::text from field_shift_offers where id = (select (r ->> 'offer')::uuid from r35sp_skip)), 'claimed/true');
-- My shifts: the standing shifts with their next dates, the availability and the rules
create temp table r35sp_my as select test.r35sp_fr('r35sp_a', 'my_shifts') as m;
grant select on r35sp_my to public;
select test.eq('my shifts: the standing shift in words', (select m -> 'standing' -> 0 ->> 'words' from r35sp_my) like 'Every %, 10:00 AM to 6:00 PM', true);
select test.eq('my shifts: the next dates with their state', (select string_agg(d ->> 'state', ',' order by d ->> 'day') from r35sp_my, jsonb_array_elements(m -> 'standing' -> 0 -> 'next') d), 'skipped,claimed,skipped,no_slot');
select test.eq('my shifts: a held shift says it is standing', (select bool_and((x ->> 'standing')::boolean) from r35sp_my, jsonb_array_elements(m -> 'mine') x), true);
select test.eq('my shifts: the rules and the count', (select (m -> 'rules' ->> 'min') || '/' || (m -> 'rules' ->> 'ahead') || '/' || (m -> 'rules' ->> 'claimed') from r35sp_my), '2/7/0');
select test.eq('my shifts: open shifts say whether they fit my availability', (select bool_and(x ? 'fits') from r35sp_my, jsonb_array_elements(m -> 'open') x), true);
-- ending: no new claims; claimed shifts stay
select test.throws('end: not someone else''s', format($$select test.r35sp_fd('r35sp_b', 'standing_end', jsonb_build_object('id', %L))$$, (select id from field_standing_shifts where staff_id = test.id('r35sp_a'))), 'not yours');
select test.eq('end: a ends it', (test.r35sp_fd('r35sp_a', 'standing_end', jsonb_build_object('id', (select id from field_standing_shifts where staff_id = test.id('r35sp_a')))) ->> 'ended')::boolean, true);
select test.eq('end: the shifts already claimed stay', test.r35sp_holds('r35sp_a', test.r35sp_slot(10, 10, 18)), true);
select test.eq('end: no longer listed', jsonb_array_length(test.r35sp_fr('r35sp_a', 'my_shifts') -> 'standing'), 0);
-- Fleet sets, drops a date of, and ends one for a person
select test.eq('Fleet: sets a standing shift for b', (test.r35sp_op('r35sp_fleet', 'field_standing_add', jsonb_build_object('staff', test.id('r35sp_b'), 'weekday', (select dow from r35sp_d), 'start', '18:00', 'end', '22:00')) ->> 'claimed')::int, 1);
select test.eq('Fleet: drops b''s claimed date (taken off, no late flag of the person)', (test.r35sp_op('r35sp_fleet', 'field_standing_skip', jsonb_build_object('id', (select id from field_standing_shifts where staff_id = test.id('r35sp_b') and ended_at is null),
  'day', app.today() + 10, 'reason', 'Moved to the lot')) ->> 'was_claimed')::boolean, true);
select test.eq('Fleet: b is off it', test.r35sp_holds('r35sp_b', test.r35sp_slot(10, 18, 22)), false);
select test.eq('Fleet: ends b''s', (test.r35sp_op('r35sp_fleet', 'field_standing_end', jsonb_build_object('id', (select id from field_standing_shifts where staff_id = test.id('r35sp_b') and ended_at is null))) ->> 'ended')::boolean, true);
select test.eq('RLS: no direct write of standing shifts or their skips from the browser', has_table_privilege('authenticated', 'field_standing_shifts', 'insert')::text || '/' || has_table_privilege('authenticated', 'field_standing_skips', 'select')::text, 'false/false');

-- ================================================================ 3. the minimum
-- b takes two shifts in the next week: at the minimum
select test.r35sp_op('r35sp_fleet', 'field_slot_publish', jsonb_build_object('starts_at', test.r35sp_at(1, 7), 'ends_at', test.r35sp_at(1, 9), 'capacity', 5, 'repeat_days', 2));
select test.r35sp_fd('r35sp_b', 'shift_take', jsonb_build_object('slot', test.r35sp_slot(1, 7, 9)));
select test.r35sp_fd('r35sp_b', 'shift_take', jsonb_build_object('slot', test.r35sp_slot(2, 7, 9)));
select app.job_field_shift_plan();
select test.eq('minimum: a (no shift in the next 7 days) gets a To do assigned to them', (select count(*) from tasks where task_type = 'field_under_minimum' and assigned_to = test.id('r35sp_a') and status = 'open'), 1::bigint);
select test.eq('minimum: and an alert', (select count(*) > 0 from app_events where payload ->> 'rule' = 'field_under_minimum' and payload ->> 'assigned_to' = test.id('r35sp_a')::text), true);
select test.eq('minimum: a text too (no phone alerts on a device)', (select count(*) from phone_outbox where dedupe_key like 'field_under_min:' || test.id('r35sp_a') || ':%'), 1::bigint);
select test.eq('minimum: b (two shifts) is not told', (select count(*) from tasks where task_type = 'field_under_minimum' and assigned_to = test.id('r35sp_b') and status = 'open'), 0::bigint);
select test.eq('minimum: d (held by the academy) is not told', (select count(*) from tasks where task_type = 'field_under_minimum' and assigned_to = test.id('r35sp_d')), 0::bigint);
select app.job_field_shift_plan();
select test.eq('minimum: at most once a day', (select count(*) from phone_outbox where dedupe_key like 'field_under_min:' || test.id('r35sp_a') || ':%')::text || '/'
  || (select count(*) from tasks where task_type = 'field_under_minimum' and assigned_to = test.id('r35sp_a'))::text, '1/1');
select test.eq('board: a is under the minimum, b is not', (select string_agg((s ->> 'name') || '=' || (s ->> 'under_min') || ':' || (s ->> 'claimed_ahead'), ',' order by s ->> 'name')
  from jsonb_array_elements(test.r35sp_or('r35sp_fleet', 'field_board') -> 'staff') s where s ->> 'id' in (test.id('r35sp_a')::text, test.id('r35sp_b')::text)), 'R35sp A=true:0,R35sp B=false:2');
select test.r35sp_fd('r35sp_a', 'shift_take', jsonb_build_object('slot', test.r35sp_slot(1, 7, 9)));
select test.eq('minimum: one shift is not enough', (select status from tasks where task_type = 'field_under_minimum' and assigned_to = test.id('r35sp_a')), 'open');
select test.r35sp_fd('r35sp_a', 'shift_take', jsonb_build_object('slot', test.r35sp_slot(2, 7, 9)));
select test.eq('minimum: reaching it closes the To do', (select status from tasks where task_type = 'field_under_minimum' and assigned_to = test.id('r35sp_a')), 'done');
update program_settings set field_min_shifts_week = 0;
select test.eq('minimum: 0 switches it off', app.fx_under_min(test.id('r35sp_e')), false);
update program_settings set field_min_shifts_week = 2;

-- ================================================================ 4. unclaimed slots, the people to ask, the board's counts
select test.r35sp_op('r35sp_fleet', 'field_slot_publish', jsonb_build_object('starts_at', test.r35sp_at(2, 10), 'ends_at', test.r35sp_at(2, 14), 'capacity', 1));
create temp table r35sp_u as select test.r35sp_slot(2, 10, 14) as id, test.r35sp_at(2, 10) as at;
grant select on r35sp_u to public;
select test.eq('suggest: e (free then, available, under the minimum); not a or b (at the minimum), not d (academy), not f (not available)',
  (select string_agg(x ->> 'name', ',') from jsonb_array_elements(app.fx_slot_suggest((select id from r35sp_u))) x where x ->> 'id' in
     (select test.id(w)::text from unnest(array['r35sp_a', 'r35sp_b', 'r35sp_d', 'r35sp_e', 'r35sp_f']) w)), 'R35sp E');
select app.job_field_shift_plan((select at from r35sp_u) - interval '50 hours');
select test.eq('unclaimed: not yet at 50 hours', (select count(*) from tasks where task_type = 'field_slot_unclaimed' and related_id = (select id from r35sp_u)), 0::bigint);
select app.job_field_shift_plan((select at from r35sp_u) - interval '30 hours');
select test.eq('unclaimed: at 30 hours Fleet gets a To do naming the people to ask', (select count(*) from tasks where task_type = 'field_slot_unclaimed' and related_id = (select id from r35sp_u)
  and queue = 'fleet' and detail like 'Ask: %R35sp E%'), 1::bigint);
select test.eq('unclaimed: and Admin and Fleet are alerted', (select count(*) from app_events where payload ->> 'rule' = 'field_slot_unclaimed' and entity_id = (select id from r35sp_u)) > 0, true);
select app.job_field_shift_plan((select at from r35sp_u) - interval '29 hours');
select test.eq('unclaimed: once only', (select count(*) from tasks where task_type = 'field_slot_unclaimed' and related_id = (select id from r35sp_u)), 1::bigint);
select test.eq('board: the slot shows how many can take it and who to ask', (select (s ->> 'available')::int >= 1 and s -> 'suggest' @> jsonb_build_array(jsonb_build_object('id', test.id('r35sp_e')))
  from jsonb_array_elements(test.r35sp_or('r35sp_fleet', 'field_board') -> 'slots') s where s ->> 'id' = (select id::text from r35sp_u)), true);
select test.eq('board: who is free when, per cell of the grid', (select (b -> 'availability_grid' -> 'cells' ->> '1:am')::int >= 4 and b -> 'rules' ->> 'alert_hours' = '48' from (select test.r35sp_or('r35sp_fleet', 'field_board') as b) x), true);
select test.eq('board: each person''s availability and standing shifts', (select (s -> 'availability' -> 'slots') @> '["6:am"]'::jsonb and jsonb_array_length(s -> 'standing') = 1
  from jsonb_array_elements(test.r35sp_or('r35sp_fleet', 'field_board') -> 'staff') s where s ->> 'id' = test.id('r35sp_c')::text), true);
select test.eq('suggest: Fleet reads the people to ask for a slot', (test.r35sp_or('r35sp_fleet', 'field_slot_suggest', jsonb_build_object('slot', (select id from r35sp_u))) -> 'suggest') @> jsonb_build_array(jsonb_build_object('id', test.id('r35sp_e'))), true);
select test.throws('suggest: customer service cannot', format($$select test.r35sp_or('r35sp_cs', 'field_slot_suggest', jsonb_build_object('slot', %L))$$, (select id from r35sp_u)), 'Not permitted');
select test.throws('board: a field person cannot read it', $$select test.r35sp_or('r35sp_e', 'field_board')$$);
select test.r35sp_op('r35sp_fleet', 'field_shift_plan_add', jsonb_build_object('staff', test.id('r35sp_e'), 'slot', (select id from r35sp_u)));
select test.eq('unclaimed: someone on it closes the To do', (select status from tasks where task_type = 'field_slot_unclaimed' and related_id = (select id from r35sp_u)), 'done');
-- a given-up slot is left to 0931's own alert
select test.r35sp_op('r35sp_fleet', 'field_slot_publish', jsonb_build_object('starts_at', test.r35sp_at(2, 15), 'ends_at', test.r35sp_at(2, 17), 'capacity', 1));
select test.r35sp_fd('r35sp_f', 'shift_take', jsonb_build_object('slot', test.r35sp_slot(2, 15, 17)));
select test.r35sp_fd('r35sp_f', 'shift_cancel', jsonb_build_object('id', (select id from field_shift_plans where staff_id = test.id('r35sp_f') and slot_id = test.r35sp_slot(2, 15, 17)), 'reason', 'Dentist'));
select app.job_field_shift_plan(test.r35sp_at(2, 15) - interval '30 hours');
select test.eq('unclaimed: a slot with an open give-up offer is not alerted twice', (select count(*) from tasks where task_type = 'field_slot_unclaimed' and related_id = test.r35sp_slot(2, 15, 17)), 0::bigint);
update program_settings set field_unclaimed_alert_hours = 0;
select test.r35sp_op('r35sp_fleet', 'field_slot_publish', jsonb_build_object('starts_at', test.r35sp_at(2, 18), 'ends_at', test.r35sp_at(2, 20), 'capacity', 1));
select app.job_field_shift_plan(test.r35sp_at(2, 18) - interval '2 hours');
select test.eq('unclaimed: 0 switches it off', (select count(*) from tasks where task_type = 'field_slot_unclaimed' and related_id = test.r35sp_slot(2, 18, 20)), 0::bigint);
update program_settings set field_unclaimed_alert_hours = 48;

-- ================================================================ clean up: the next suites publish their own slots
update field_standing_shifts set ended_at = now(), ended_by = test.id('r35sp_admin') where ended_at is null;
update field_shift_plans set cancelled_at = now(), cancelled_by = test.id('r35sp_admin') where cancelled_at is null and staff_id in (select test.id(w) from unnest(array['r35sp_a', 'r35sp_b', 'r35sp_c', 'r35sp_d', 'r35sp_e', 'r35sp_f']) w);
update field_shift_slots set cancelled_at = now(), cancelled_by = test.id('r35sp_admin') where cancelled_at is null and created_by = test.id('r35sp_fleet');
update field_shift_offers set status = 'withdrawn' where status = 'open';
