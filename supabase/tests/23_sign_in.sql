-- 23: sign-in for every portal (migration 0036): view as, Admin > Portals, invitations into any role, the password
-- link's address, the live verification's Admin and assistants, the lighter frame counts. Fixtures start with "si".
select test.suite('23 sign in');

select test.mk_user('si_admin', 'admin');
select test.mk_user('si_admin2', 'admin');
select test.mk_user('si_cs', 'va', 'cs');
update staff_profiles set cover_functions = '{fleet}' where user_id = test.id('si_cs');
select test.mk_user('si_field', 'field');
select test.mk_owner('si_o');
select test.mk_renter('si_r');
select public.register_account(test.id('si_newr'), 'si_newr@example.test', 'Si New Renter', null);
insert into users (id, email, full_name) values (test.id('si_inv'), 'si_inv@example.test', 'Si Investor');
insert into investors (id, user_id, legal_name, investor_type, status, email) values (test.id('inv:si'), test.id('si_inv'), 'Si Investor', 'individual', 'active', 'si_inv@example.test');
insert into investors (id, legal_name, investor_type, status, email) values (test.id('inv:si_new'), 'Si New Investor', 'individual', 'active', 'si_new_inv@example.test');
insert into owners (id, owner_type, legal_name, status, email) values (test.id('owner:si_new'), 'individual', 'Si New Owner', 'active', 'si_new_owner@example.test');

-- ---------------------------------------------------------------- 1. view as
set role service_role;
select test.eq('view as: an Admin opens an owner''s portal; the banner gets the name and email',
  (select r ->> 'name' || '/' || (r ->> 'email') || '/' || (r ->> 'portal') from (select public.server_view_as_start(test.id('si_admin'), test.id('si_o'), 'owner') r) x),
  'Si O/si_o@example.test/owner');
select test.eq('view as: an assistant''s portal opens in their main function by default',
  public.server_view_as_start(test.id('si_admin'), test.id('si_cs'), 'va') ->> 'function', 'cs');
select test.eq('view as: or in a function they cover',
  public.server_view_as_start(test.id('si_admin'), test.id('si_cs'), 'va', 'fleet') ->> 'function', 'fleet');
select test.throws('view as: not in a function they do not work in',
  format('select public.server_view_as_start(%L, %L, %L, %L)', test.id('si_admin'), test.id('si_cs'), 'va', 'finance'), 'does not work as finance');
select test.lives('view as: field, investor and renter portals open for their people',
  format('select public.server_view_as_start(%L, %L, ''field''), public.server_view_as_start(%L, %L, ''investor''), public.server_view_as_start(%L, %L, ''account'')',
         test.id('si_admin'), test.id('si_field'), test.id('si_admin'), test.id('si_inv'), test.id('si_admin'), test.id('si_r')));
select test.throws('view as: a portal the person does not have is refused',
  format('select public.server_view_as_start(%L, %L, ''owner'')', test.id('si_admin'), test.id('si_cs')), 'is not an owner');
select test.throws('view as: only an Admin may',
  format('select public.server_view_as_start(%L, %L, ''owner'')', test.id('si_cs'), test.id('si_o')), 'Only an Admin');
select test.throws('view as: not as yourself',
  format('select public.server_view_as_start(%L, %L, ''account'')', test.id('si_admin'), test.id('si_admin')), 'already signed in as yourself');
select test.throws('view as: an unknown portal is refused',
  format('select public.server_view_as_start(%L, %L, ''admin'')', test.id('si_admin'), test.id('si_admin2')), 'Unknown portal');
reset role;
update users set status = 'suspended' where id = test.id('si_field');
set role service_role;
select test.throws('view as: not an account whose access has ended',
  format('select public.server_view_as_start(%L, %L, ''field'')', test.id('si_admin'), test.id('si_field')), 'not active');
reset role;
update users set status = 'active' where id = test.id('si_field');
select test.eq('view as: every start is in the audit log with the portal',
  (select count(*) from audit_log where action = 'view_as_start' and actor_user_id = test.id('si_admin') and entity_id <> test.id('si_newr')::text), 6::bigint);
select test.eq('view as: with the person and the function',
  (select after ->> 'portal' || '/' || (after ->> 'function') from audit_log where action = 'view_as_start' and entity_id = test.id('si_cs')::text order by id desc limit 1),
  'va/fleet');
set role authenticated;
select test.throws('view as: a browser cannot start it', format('select public.server_view_as_start(%L, %L, ''owner'')', test.id('si_admin'), test.id('si_o')), 'permission denied');
reset role;

select test.eq('roles: an account made on the site has the renter portal before its first booking',
  (public.my_roles(test.id('si_newr')) ->> 'renter') || '/' || (app.person_portals(test.id('si_newr')) ->> 'renter'), 'true/true');
set role service_role;
select test.lives('view as: the renter portal of an account with no booking yet', format('select public.server_view_as_start(%L, %L, ''account'')', test.id('si_admin'), test.id('si_newr')));
reset role;

-- ---------------------------------------------------------------- 2. Admin > Portals
set role service_role;
select test.eq('portals: each person with the portals they have',
  (select concat_ws(',', case when (p -> 'portals' ->> 'admin')::boolean then 'admin' end, p -> 'portals' -> 'va_functions' ->> 0, p -> 'portals' -> 'va_functions' ->> 1)
     from jsonb_array_elements(public.admin_portal_people(test.id('si_admin'), 'si_cs') -> 'people') p), 'cs,fleet');
select test.eq('portals: search by name or email',
  (select string_agg(p ->> 'email', ',' order by p ->> 'email') from jsonb_array_elements(public.admin_portal_people(test.id('si_admin'), 'si_o@') -> 'people') p), 'si_o@example.test');
select test.ok('portals: an owner and an investor on file without a sign-in are listed for an invitation',
  public.admin_portal_people(test.id('si_admin')) -> 'owners_without_account' @> jsonb_build_array(jsonb_build_object('id', test.id('owner:si_new')))
  and public.admin_portal_people(test.id('si_admin')) -> 'investors_without_account' @> jsonb_build_array(jsonb_build_object('id', test.id('inv:si_new'))));
select test.ok('portals: a search with % or _ matches them literally',
  jsonb_array_length(public.admin_portal_people(test.id('si_admin'), '%') -> 'people') = 0);
select test.throws('portals: Admin only', format('select public.admin_portal_people(%L)', test.id('si_cs')), 'Only an Admin');
select test.eq('portals: each owner and investor record with its sign-in',
  (public.admin_account_index(test.id('si_admin')) -> 'owners' -> test.id('owner:si_o')::text ->> 'email') || '/' ||
  (public.admin_account_index(test.id('si_admin')) -> 'investors' -> test.id('inv:si')::text ->> 'email'), 'si_o@example.test/si_inv@example.test');
select test.ok('portals: a record without a sign-in is not in the index', not (public.admin_account_index(test.id('si_admin')) -> 'investors' ? test.id('inv:si_new')::text));
select test.throws('portals: the index is Admin only', format('select public.admin_account_index(%L)', test.id('si_cs')), 'Only an Admin');
reset role;

-- ---------------------------------------------------------------- 3. invitations into any role
set role service_role;
select test.eq('invite: an assistant with a main function and the functions they cover',
  (select (r -> 'roles' ->> 'va') || '/' || (r -> 'roles' ->> 'va_functions') from (select public.admin_invite_account(test.id('si_admin'),
     jsonb_build_object('user_id', test.id('si_newva'), 'email', 'SI_NewVA@example.test', 'full_name', 'Si New VA', 'role', 'va', 'va_function', 'finance',
                        'cover_functions', jsonb_build_array('sales', 'finance'))) r) x),
  'finance/["finance", "sales"]');
select test.eq('invite: the address is stored in lower case', (select email from users where id = test.id('si_newva')), 'si_newva@example.test');
select test.eq('invite: an Admin',
  public.admin_invite_account(test.id('si_admin'), jsonb_build_object('user_id', test.id('si_newadmin'), 'email', 'si_newadmin@example.test', 'full_name', 'Si New Admin', 'role', 'admin')) -> 'roles' ->> 'admin', 'true');
select test.eq('invite: field staff',
  public.admin_invite_account(test.id('si_admin'), jsonb_build_object('user_id', test.id('si_newfield'), 'email', 'si_newfield@example.test', 'full_name', 'Si New Field', 'role', 'field', 'field_function', 'detailer')) -> 'roles' ->> 'field', 'true');
select test.eq('invite: an owner on file gets their sign-in',
  public.admin_invite_account(test.id('si_admin'), jsonb_build_object('user_id', test.id('si_newowner'), 'email', 'si_new_owner@example.test', 'role', 'owner', 'owner_id', test.id('owner:si_new'))) -> 'roles' ->> 'owner', 'true');
select test.eq('invite: the owner record now points to the sign-in, with the owner''s name',
  (select o.user_id::text || '/' || u.full_name from owners o join users u on u.id = o.user_id where o.id = test.id('owner:si_new')), test.id('si_newowner')::text || '/Si New Owner');
select test.eq('invite: an investor on file',
  public.admin_invite_account(test.id('si_admin'), jsonb_build_object('user_id', test.id('si_newinv'), 'email', 'si_new_inv@example.test', 'role', 'investor', 'investor_id', test.id('inv:si_new'))) -> 'roles' ->> 'investor', 'true');
select test.throws('invite: an owner who already has another sign-in is refused',
  format('select public.admin_invite_account(%L, %L::jsonb)', test.id('si_admin'), jsonb_build_object('user_id', gen_random_uuid(), 'email', 'x1@example.test', 'role', 'owner', 'owner_id', test.id('owner:si_new'))), 'already has a sign-in');
select test.throws('invite: an address on another record is refused',
  format('select public.admin_invite_account(%L, %L::jsonb)', test.id('si_admin'), jsonb_build_object('user_id', gen_random_uuid(), 'email', 'si_o@example.test', 'full_name', 'X', 'role', 'va', 'va_function', 'cs')), 'is on another record');
select test.throws('invite: an assistant needs a function',
  format('select public.admin_invite_account(%L, %L::jsonb)', test.id('si_admin'), jsonb_build_object('user_id', gen_random_uuid(), 'email', 'x2@example.test', 'full_name', 'X', 'role', 'va')), 'function');
select test.throws('invite: only these roles',
  format('select public.admin_invite_account(%L, %L::jsonb)', test.id('si_admin'), jsonb_build_object('user_id', gen_random_uuid(), 'email', 'x3@example.test', 'full_name', 'X', 'role', 'renter')), 'Choose the role');
select test.throws('invite: Admin only',
  format('select public.admin_invite_account(%L, %L::jsonb)', test.id('si_cs'), jsonb_build_object('user_id', gen_random_uuid(), 'email', 'x4@example.test', 'full_name', 'X', 'role', 'admin')), 'Only an Admin');
select test.lives('invite: a second role for a person who already has one (a renter made an assistant)',
  format('select public.admin_invite_account(%L, %L::jsonb)', test.id('si_admin'), jsonb_build_object('user_id', test.id('si_r'), 'email', 'si_r@example.test', 'role', 'va', 'va_function', 'sales')));
select test.eq('invite: they keep the renter portal and gain the assistant''s',
  (select (p ->> 'renter') || '/' || (p -> 'va_functions' ->> 0) from (select app.person_portals(test.id('si_r')) p) x), 'true/sales');
select test.eq('invite: each invitation is in the audit log', (select count(*) from audit_log where action = 'invite_account' and actor_user_id = test.id('si_admin')), 6::bigint);
select test.eq('password link: the address, recorded', public.admin_account_link(test.id('si_admin'), test.id('si_o')) ->> 'email', 'si_o@example.test');
select test.ok('password link: in the audit log', exists (select 1 from audit_log where action = 'send_password_link' and entity_id = test.id('si_o')::text));
select test.throws('password link: Admin only', format('select public.admin_account_link(%L, %L)', test.id('si_cs'), test.id('si_o')), 'Only an Admin');
select test.eq('an address finds its record (an invitation to someone who already signs in)', public.server_user_by_email(' SI_O@example.test '), test.id('si_o'));
reset role;
set role authenticated;
select test.throws('invite: a browser cannot', format('select public.admin_invite_account(%L, %L::jsonb)', test.id('si_admin'), '{}'), 'permission denied');
select test.throws('an address lookup is server only', $$select public.server_user_by_email('si_o@example.test')$$, 'permission denied');
reset role;

-- ---------------------------------------------------------------- 4. the live verification's accounts
set role service_role;
create temp table si_va as select public.server_verify_accounts(jsonb_build_array(
  jsonb_build_object('user_id', test.id('si_v_admin'), 'email', 'verify-admin@carmacars.ca', 'role', 'admin'),
  jsonb_build_object('user_id', test.id('si_v_fin'), 'email', 'verify-va-finance@carmacars.ca', 'role', 'va_finance'),
  jsonb_build_object('user_id', test.id('si_v_fleet'), 'email', 'verify-va-fleet@carmacars.ca', 'role', 'va_fleet'),
  jsonb_build_object('user_id', test.id('si_v_sales'), 'email', 'verify-va-sales@carmacars.ca', 'role', 'va_sales'))) r;
select test.eq('verify accounts: the Admin and one assistant per function',
  (select string_agg(x ->> 'role' || '=' || coalesce(x -> 'roles' ->> 'va', '') || case when (x -> 'roles' ->> 'admin')::boolean then 'admin' else '' end, ',') from si_va, jsonb_array_elements(r) x),
  'admin=admin,va_finance=finance,va_fleet=fleet,va_sales=sales');
select test.throws('verify accounts: an Admin role on any other verification address is refused',
  format($$select public.server_verify_accounts(jsonb_build_array(jsonb_build_object('user_id', %L, 'email', 'verify-va-sales@carmacars.ca', 'role', 'admin')))$$, test.id('si_v_sales')), 'Only verify-admin');
reset role;
insert into user_roles (user_id, role) values (test.id('si_v_fin'), 'admin');
set role service_role;
select public.server_verify_accounts(jsonb_build_array(jsonb_build_object('user_id', test.id('si_v_fin'), 'email', 'verify-va-finance@carmacars.ca', 'role', 'va_finance')));
select test.eq('verify accounts: an Admin role on an assistant is taken away again', public.my_roles(test.id('si_v_fin')) ->> 'admin', 'false');
reset role;
select test.eq('verify accounts: all on the suppression list',
  (select count(*) from email_suppressions where email in ('verify-admin@carmacars.ca', 'verify-va-finance@carmacars.ca', 'verify-va-fleet@carmacars.ca', 'verify-va-sales@carmacars.ca') and scope = 'all' and lifted_at is null), 4::bigint);

-- ---------------------------------------------------------------- 5. lighter frames
insert into notifications (user_id, code, title, body, dedupe_key) values
  (test.id('si_o'), 'renter_offer_ready', 'One', 'b', 'si:n1'), (test.id('si_o'), 'renter_offer_ready', 'Two', 'b', 'si:n2');
insert into notifications (user_id, code, title, body, dedupe_key, read_at) values (test.id('si_o'), 'renter_offer_ready', 'Read', 'b', 'si:n3', now());
select test.login(test.id('si_o'));
select test.eq('frame: the unread count without the notices', public.my_unread_count(), 2);
select test.logout();
set role anon;
select test.throws('frame: the count needs a sign-in', 'select public.my_unread_count()', 'permission denied');
reset role;
set role service_role;
select test.eq('rail: the Admin rail counts are the dashboard''s',
  (select (c ->> 'requests')::int = jsonb_array_length(d -> 'requests') and (c ->> 'statements')::int = (d -> 'approvals' ->> 'statements')::int
          and (c ->> 'refunds')::int = (d -> 'approvals' ->> 'refunds')::int and (c ->> 'listings')::int = (d -> 'approvals' ->> 'listings')::int
          and (c ->> 'tolls')::int = (d -> 'approvals' ->> 'tolls')::int
     from (select public.admin_rail_counts(test.id('si_admin')) c, app.admin_dashboard(test.id('si_admin')) d) x), true);
select test.throws('rail: Admin only', format('select public.admin_rail_counts(%L)', test.id('si_cs')), 'Only an Admin');
reset role;
