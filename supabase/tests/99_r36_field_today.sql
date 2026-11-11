-- 99: field staff working today on every office Schedule page and the staff home (migration 2250). Fixtures start with
-- "ft2"; addresses are example.test.
select test.suite('99 field staff working today');

select test.mk_user('ft2_admin', 'admin');
select test.mk_user('ft2_cs', 'va', 'cs');
select test.mk_user('ft2_sales', 'va', 'sales');
select test.mk_user('ft2_field_on', 'field', null, 'driver');
select test.mk_user('ft2_field_tmrw', 'field', null, 'driver');
select test.mk_user('ft2_field_off', 'field', null, 'detailer');
update users set greeting_name = 'Ftwo' where id = test.id('ft2_field_on');

with s as (insert into field_shift_slots (starts_at, ends_at, capacity) values (now() - interval '1 hour', now() + interval '2 hours', 3) returning id, starts_at, ends_at)
insert into field_shift_plans (slot_id, staff_id, starts_at, ends_at, cancelled_at, cancelled_by)
select s.id, test.id(x.u), s.starts_at, s.ends_at, case when x.c then now() end, case when x.c then test.id('ft2_admin') end
  from s cross join (values ('ft2_field_on', false), ('ft2_field_off', true)) x(u, c);
-- a shift tomorrow is not today's
with s as (insert into field_shift_slots (starts_at, ends_at, capacity) values (now() + interval '25 hours', now() + interval '28 hours', 3) returning id, starts_at, ends_at)
insert into field_shift_plans (slot_id, staff_id, starts_at, ends_at) select s.id, test.id('ft2_field_tmrw'), s.starts_at, s.ends_at from s;

select test.ok('Customer service sees the field person on shift now, by preferred name',
  exists (select 1 from jsonb_array_elements(public.door(test.id('ft2_cs'), 'aal2', 'ops_read', 'staff_schedules', '{}'::jsonb) -> 'field_today') e
           where e ->> 'user_id' = test.id('ft2_field_on')::text and e ->> 'name' = 'Ftwo' and e ->> 'state' = 'on'));
select test.ok('Sales sees the same list',
  exists (select 1 from jsonb_array_elements(public.door(test.id('ft2_sales'), 'aal2', 'ops_read', 'staff_schedules', '{}'::jsonb) -> 'field_today') e
           where e ->> 'user_id' = test.id('ft2_field_on')::text));
select test.ok('a shift tomorrow and a cancelled shift today are not listed',
  not exists (select 1 from jsonb_array_elements(app.field_on_today(now())) e
               where e ->> 'user_id' in (test.id('ft2_field_tmrw')::text, test.id('ft2_field_off')::text)));
select test.ok('a browser session cannot call the list directly',
  not has_function_privilege('authenticated', 'app.field_on_today(timestamptz)', 'execute'));
