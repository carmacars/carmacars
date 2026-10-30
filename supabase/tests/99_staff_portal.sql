-- 99: one staff portal (migration 0197). A staff member holds any set of functions (cs, fleet, finance, sales, field);
-- permissions come from the set (app.user_va_has: holds any; app.user_is_field: holds field); the function chosen on screen
-- (app.va_active_fn) is one of the held office functions. The older columns follow the set; existing rows were moved by
-- app.staff_legacy_functions. Links point at /staff. Fixtures start with "stp".
select test.suite('99 staff portal');

select test.mk_user('stp_admin', 'admin');
select test.mk_user('stp_cs', 'va', 'cs');
select test.mk_user('stp_sales', 'va', 'sales');
select test.mk_user('stp_field', 'field', null, 'driver');
select test.mk_user('stp_both', 'va', 'sales');

-- ================================================================ 1. the migration of existing rows
select test.eq('cs only', app.staff_legacy_functions('va', 'cs', '{}', null), array['cs']);
select test.eq('sales with cover: sales first, then the cover', app.staff_legacy_functions('va', 'sales', array['cs', 'sales', 'finance'], null), array['sales', 'cs', 'finance']);
select test.eq('field only', app.staff_legacy_functions('field', null, '{}', 'driver'), array['field']);
select test.eq('sales and field', app.staff_legacy_functions('va', 'sales', '{}', 'driver_detailer'), array['sales', 'field']);
select test.eq('an older insert gets its set (cs)', (select functions from staff_profiles where user_id = test.id('stp_cs')), array['cs']);
select test.eq('an older insert gets its set (field)', (select functions from staff_profiles where user_id = test.id('stp_field')), array['field']);
select test.ok('no staff row without a function', not exists (select 1 from staff_profiles where cardinality(functions) = 0));

-- an older writer (the cover functions) changes the set
update staff_profiles set cover_functions = array['fleet']::va_function[] where user_id = test.id('stp_cs');
select test.eq('cover functions written the older way join the set', (select functions from staff_profiles where user_id = test.id('stp_cs')), array['cs', 'fleet']);

-- ================================================================ 2. Sales in person and field work, one person
select test.eq('Admin sets sales (in person) and field',
  public.door(test.id('stp_admin'), 'aal2', 'admin_do', 'staff_functions',
    jsonb_build_object('user_id', test.id('stp_both'), 'functions', jsonb_build_array('sales', 'field'), 'sales_work_mode', 'in_person', 'field_function', 'driver')) -> 'functions',
  '["sales", "field"]'::jsonb);
select test.eq('the older columns follow',
  (select staff_type || '/' || va_function || '/' || cardinality(cover_functions) || '/' || field_function || '/' || sales_work_mode from staff_profiles where user_id = test.id('stp_both')),
  'va/sales/0/driver/in_person');
select test.eq('both roles', (select string_agg(role::text, ',' order by role::text) from user_roles where user_id = test.id('stp_both')), 'field,va');
select test.ok('holds sales', app.user_va_has(test.id('stp_both'), 'sales'));
select test.ok('any office function', app.user_va_has(test.id('stp_both')));
select test.ok('not customer service', not app.user_va_has(test.id('stp_both'), 'cs'));
select test.ok('field work', app.user_is_field(test.id('stp_both')));
select test.ok('may do handovers', app.user_may_handover(test.id('stp_both')));
select test.eq('works as sales', app.va_active_fn(test.id('stp_both')), 'sales');
select test.ok('request reads as Sales', app.request_user_is_sales(test.id('stp_both')));
select test.eq('my_roles: every function and the mode',
  (select (r ->> 'va') || '/' || (r -> 'functions')::text || '/' || (r ->> 'field') || '/' || (r ->> 'sales_work_mode') from (select public.my_roles(test.id('stp_both')) r) x),
  'sales/["sales", "field"]/true/in_person');
select test.eq('Admin > Portals reads the set', app.person_portals(test.id('stp_both')) -> 'functions', '["sales", "field"]'::jsonb);
select test.eq('the Sales mode reads the set', app.swm_mode(test.id('stp_both')), 'in_person');

-- ================================================================ 3. held functions, and the one chosen on screen
select test.ok('cs+fleet holds fleet', app.user_va_has(test.id('stp_cs'), 'fleet'));
select test.ok('cs+fleet holds cs', app.user_va_has(test.id('stp_cs'), 'cs'));
select test.ok('cs+fleet holds no finance', not app.user_va_has(test.id('stp_cs'), 'finance'));
select test.eq('first office function by default', app.va_active_fn(test.id('stp_cs')), 'cs');
select set_config('app.va_active', 'fleet', false);
select test.eq('the function chosen on screen', app.va_active_fn(test.id('stp_cs')), 'fleet');
select set_config('app.va_active', 'finance', false);
select test.eq('a function not held is ignored', app.va_active_fn(test.id('stp_cs')), 'cs');
select set_config('app.va_active', 'field', false);
select test.eq('field is not an office function to work in', app.va_active_fn(test.id('stp_both')), 'sales');
select set_config('app.va_active', '', false);
select test.ok('field only: no office function', not app.user_va_has(test.id('stp_field')));
select test.ok('field only: field work', app.user_is_field(test.id('stp_field')));
select test.eq('field only: nothing to work in', app.va_active_fn(test.id('stp_field')), null::text);
select test.ok('cs only: no field work', not app.user_is_field(test.id('stp_sales')) and not app.user_is_field(test.id('stp_cs')));

-- ================================================================ 4. changing the set
select public.door(test.id('stp_admin'), 'aal2', 'admin_do', 'staff_functions', jsonb_build_object('user_id', test.id('stp_field'), 'functions', jsonb_build_array('field', 'cs')));
select test.eq('field staff given customer service', (select staff_type || '/' || va_function || '/' || field_function from staff_profiles where user_id = test.id('stp_field')), 'va/cs/driver');
select test.ok('and now holds cs', app.user_va_has(test.id('stp_field'), 'cs') and app.user_is_field(test.id('stp_field')));
select public.door(test.id('stp_admin'), 'aal2', 'admin_do', 'staff_functions', jsonb_build_object('user_id', test.id('stp_both'), 'functions', jsonb_build_array('sales')));
select test.ok('field work taken away', not app.user_is_field(test.id('stp_both'))
  and (select field_function is null from staff_profiles where user_id = test.id('stp_both'))
  and not exists (select 1 from user_roles where user_id = test.id('stp_both') and role = 'field'));
select test.throws('at least one function',
  format($s$select public.door(%L, 'aal2', 'admin_do', 'staff_functions', '{"user_id": "%s", "functions": []}')$s$, test.id('stp_admin'), test.id('stp_both')), 'at least one function');
select test.throws('known functions only',
  format($s$select public.door(%L, 'aal2', 'admin_do', 'staff_functions', '{"user_id": "%s", "functions": ["va"]}')$s$, test.id('stp_admin'), test.id('stp_both')), 'Functions are');
select test.throws('an Admin only',
  format($s$select public.door(%L, 'aal2', 'admin_do', 'staff_functions', '{"user_id": "%s", "functions": ["cs"]}')$s$, test.id('stp_sales'), test.id('stp_both')));

-- the invitation with a set (the hire)
select test.eq('invite as staff with sales (remote) and field',
  (select (r -> 'roles' -> 'functions')::text || '/' || (r -> 'roles' ->> 'field') from (select public.admin_invite_account(test.id('stp_admin'),
     jsonb_build_object('user_id', test.id('stp_new'), 'email', 'stp_new@example.test', 'full_name', 'Stp New', 'role', 'staff',
                        'functions', jsonb_build_array('sales', 'field'), 'sales_work_mode', 'remote')) r) x),
  '["sales", "field"]/true');
select test.eq('the invited mode', (select sales_work_mode || '/' || field_function from staff_profiles where user_id = test.id('stp_new')), 'remote/driver_detailer');

-- ================================================================ 5. links
select test.ok('no notification links to /va or /field', not exists (select 1 from notification_catalogue where link_path ~ '^/(va|field)(/|$)'));
select test.eq('a booking link', (select link_path from notification_catalogue where code = 'staff_request_waiting'), '/staff/bookings/{{booking_number}}');
select test.eq('a field job link', (select link_path from notification_catalogue where code = 'staff_field_job_assigned'), '/staff/field/jobs/{{job_id}}');
select test.ok('no database function writes a /va or /field link', not exists (
  select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.prosrc ~ $r$'/(va|field)[/']$r$ and p.proname !~ '_(pre)?0[0-9]{3}[a-z]?$'));
