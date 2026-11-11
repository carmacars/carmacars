-- 99: role KPIs (1504). Customer service's first reply against the 5-minute target, conversations, licences and requests;
-- Fleet's on-time handovers, dispatches and calls; Finance's toll checks; field staff's jobs, on time and photos; every
-- target a Program setting; the KPIs on the scorecard; the Admin sees everyone, a staff member only themselves.
-- Fixtures start with "kpx"; addresses are example.test.
select test.suite('99 r35c role kpis');

select test.mk_user('kpx_admin', 'admin');
select test.mk_user('kpx_cs', 'va', 'cs');
select test.mk_user('kpx_fleet', 'va', 'fleet');
select test.mk_user('kpx_fin', 'va', 'finance');
select test.mk_user('kpx_field', 'field');
update staff_profiles set functions = array[va_function::text] where user_id in (test.id('kpx_cs'), test.id('kpx_fleet'), test.id('kpx_fin'));
update staff_profiles set functions = array['field'] where user_id = test.id('kpx_field');
select test.mk_owner('kpx_own');
select test.mk_vehicle('kpx_car', 'kpx_own');
create function test.kpx_wk() returns date language sql stable as $$ select (date_trunc('week', app.today()::timestamp))::date $$;
create function test.kpx_item(p_user text, p_key text) returns jsonb language sql stable as $$
  select x from jsonb_array_elements(app.role_kpis(test.id(p_user), test.kpx_wk())) x where x ->> 'key' = p_key $$;

-- customer service: two threads this week, one answered in 3 minutes, one in 12
do $$
declare t1 uuid := gen_random_uuid(); t2 uuid := gen_random_uuid(); a timestamptz := app.local_midnight(test.kpx_wk()) + interval '9 hours';
begin
  if a > now() - interval '1 hour' then a := now() - interval '1 hour'; end if;
  insert into phone_threads (id, number) values (t1, '+16475550901'), (t2, '+16475550902');
  insert into phone_activity (thread_id, kind, direction, started_at, staff_user_id) values
    (t1, 'text', 'in', a, null), (t1, 'text', 'out', a + interval '3 minutes', test.id('kpx_cs')),
    (t2, 'text', 'in', a + interval '10 minutes', null), (t2, 'text', 'out', a + interval '22 minutes', test.id('kpx_cs')),
    (t2, 'call', 'out', a + interval '30 minutes', test.id('kpx_fleet'));
end $$;
select test.eq('first reply: 1 of 2 within 5 minutes, 50%, not met (target 90)',
  (select format('%s|%s|%s', i ->> 'value', i ->> 'target', i ->> 'met') from (select test.kpx_item('kpx_cs', 'cs_first_reply') i) x), '50|90|false');
select test.eq('conversations handled: 2, target from the setting (40)', (select format('%s|%s', i ->> 'value', i ->> 'target') from (select test.kpx_item('kpx_cs', 'cs_conversations') i) x), '2|40');
update program_settings set kpi_cs_first_reply_minutes = 15, kpi_cs_conversations_week = 2;
select test.eq('the targets are settings: 15 minutes makes both on time; 2 conversations is met',
  format('%s|%s', test.kpx_item('kpx_cs', 'cs_first_reply') ->> 'met', test.kpx_item('kpx_cs', 'cs_conversations') ->> 'met'), 'true|true');
select test.eq('Fleet: one call', test.kpx_item('kpx_fleet', 'fleet_calls') ->> 'value', '1');

-- field: two jobs done this week by the field person dispatched by Fleet, one late
insert into field_jobs (kind, vehicle_id, assigned_to, dispatched_by, scheduled_at, status, completed_at)
values ('handover', test.id('vehicle:kpx_car'), test.id('kpx_field'), test.id('kpx_fleet'), greatest(app.local_midnight(test.kpx_wk()), now() - interval '3 hours'), 'done', greatest(app.local_midnight(test.kpx_wk()), now() - interval '3 hours') + interval '5 minutes'),
       ('detail', test.id('vehicle:kpx_car'), test.id('kpx_field'), test.id('kpx_fleet'), greatest(app.local_midnight(test.kpx_wk()), now() - interval '3 hours'), 'done', greatest(app.local_midnight(test.kpx_wk()), now() - interval '3 hours') + interval '2 hours');
select test.eq('field: 2 jobs done, 1 of 2 on time',
  format('%s|%s', test.kpx_item('kpx_field', 'field_jobs') ->> 'value', test.kpx_item('kpx_field', 'field_on_time') ->> 'value'), '2|50');
select test.eq('field: the handover had no condition report: photos 0 of 1', test.kpx_item('kpx_field', 'field_photos') ->> 'detail', '0 of 1');
select test.eq('Fleet: 2 field jobs dispatched; the team''s handover on time', format('%s|%s', test.kpx_item('kpx_fleet', 'fleet_dispatched') ->> 'value', test.kpx_item('kpx_fleet', 'fleet_handovers_on_time') ->> 'value'), '2|100');
select test.eq('Finance: tolls and tickets checked on 0 days, target 2', format('%s|%s|%s', test.kpx_item('kpx_fin', 'finance_toll_checks') ->> 'value', test.kpx_item('kpx_fin', 'finance_toll_checks') ->> 'target', test.kpx_item('kpx_fin', 'finance_toll_checks') ->> 'met'), '0|2|false');
select test.ok('Finance has the deposits and the statements KPIs', test.kpx_item('kpx_fin', 'finance_deposits') is not null and test.kpx_item('kpx_fin', 'finance_statements') is not null);

-- ================================================================ the scorecard, the board, who sees what
select test.ok('the scorecard carries the KPIs by week', jsonb_array_length(app.staff_scorecard(test.id('kpx_cs'), 6) -> 'kpis') = 4);
select test.ok('the Admin sees everyone', (select count(*) from jsonb_array_elements(app.door(test.id('kpx_admin'), 'aal2', 'admin_read', 'kpi_board') -> 'people') p
  where p ->> 'user_id' in (test.id('kpx_cs')::text, test.id('kpx_fleet')::text, test.id('kpx_fin')::text, test.id('kpx_field')::text)) = 4);
select test.eq('a staff member sees only themselves', (select string_agg(p ->> 'user_id', ',') from jsonb_array_elements(app.door(test.id('kpx_cs'), 'aal2', 'ops_read', 'kpi_board') -> 'people') p), test.id('kpx_cs')::text);
select test.eq('the field person sees their own from the field portal', (select count(*) from jsonb_array_elements(app.door(test.id('kpx_field'), 'aal2', 'field_read', 'kpi_board') -> 'people') p), 1::bigint);

update program_settings set kpi_cs_first_reply_minutes = 5, kpi_cs_conversations_week = 40;
