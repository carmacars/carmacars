-- 0036_sign_in.sql
-- Sign-in for every portal (docs/changes/0036_sign_in.md, docs/changes/2026-10-14-sign-in.md):
--   1. view as: an Admin opens another person's portal read only. app.view_as_start checks the Admin, the person
--      and the portal, and writes the start to the audit log; the web app keeps the choice in a signed, short-lived
--      cookie and refuses every write while it is set.
--   2. Admin > Portals: everyone who can sign in, with the portals each one has (app.admin_portal_people), and the
--      owners and investors on file who have no sign-in yet.
--   3. invitations into any role: admin, assistant (with the functions covered), field, owner (an owner on file),
--      investor (an investor on file) through app.admin_invite_account; the address for a password link.
--   4. the live verification's accounts: an Admin (verify-admin@carmacars.ca only) and one assistant per function.
--   5. lighter portal frames: the unread count and the Admin rail's counts without the full lists.
-- No earlier migration is edited.

-- ================================================================ 1. view as
-- my_roles (0033) with one change: "renter" is also true for an account made on the site (its renter role) before its
-- first booking makes the renters row, so the sign-in and the portal lists offer "My rentals" to it.
create or replace function app.my_roles(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'admin', app.user_is_admin(p_user),
    'va', (select app.va_active_fn(sp.user_id) from staff_profiles sp join user_roles r on r.user_id = sp.user_id and r.role = 'va'
             join users u on u.id = sp.user_id
            where sp.user_id = p_user and sp.staff_type = 'va' and sp.is_active and u.status = 'active' limit 1),
    'va_functions', coalesce((select to_jsonb(array[sp.va_function::text] || array(select x::text from unnest(sp.cover_functions) x where x <> sp.va_function))
                                from staff_profiles sp join user_roles r on r.user_id = sp.user_id and r.role = 'va' join users u on u.id = sp.user_id
                               where sp.user_id = p_user and sp.staff_type = 'va' and sp.is_active and u.status = 'active' limit 1), '[]'::jsonb),
    'field', app.user_is_field(p_user),
    'owner', exists (select 1 from owners o where o.user_id = p_user),
    'renter', exists (select 1 from renters r where r.user_id = p_user) or exists (select 1 from user_roles r where r.user_id = p_user and r.role = 'renter'),
    'investor', exists (select 1 from investors i where i.user_id = p_user and i.status in ('active', 'exited')),
    'staff', app.user_is_admin(p_user) or app.user_is_staff(p_user) or app.user_is_field(p_user),
    'two_step_required', coalesce((app.settings()).require_staff_two_step, false),
    'name', (select u.full_name from users u where u.id = p_user))
$$;

-- The portals a person has, in the order the sign-in offers them.
create or replace function app.person_portals(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'admin', app.user_is_admin(p_user),
    'va_functions', coalesce((select to_jsonb(array[sp.va_function::text] || array(select x::text from unnest(sp.cover_functions) x where x <> sp.va_function))
                                from staff_profiles sp join user_roles r on r.user_id = sp.user_id and r.role = 'va' join users u on u.id = sp.user_id
                               where sp.user_id = p_user and sp.staff_type = 'va' and sp.is_active and u.status = 'active' limit 1), '[]'::jsonb),
    'field', app.user_is_field(p_user),
    'owner', exists (select 1 from owners o where o.user_id = p_user),
    'investor', exists (select 1 from investors i where i.user_id = p_user and i.status in ('active', 'exited')),
    'renter', exists (select 1 from renters r where r.user_id = p_user) or exists (select 1 from user_roles r where r.user_id = p_user and r.role = 'renter'))
$$;

-- An Admin starts viewing a portal as another person. Returns who, for the banner; refuses anything else.
create or replace function app.view_as_start(p_admin uuid, p_target uuid, p_portal text, p_fn text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  u users;
  v_p jsonb;
  v_fn text := nullif(btrim(coalesce(p_fn, '')), '');
begin
  perform app.assert_admin(p_admin);
  select * into u from users where id = p_target;
  if u.id is null then raise exception 'That person is not on file' using errcode = 'P0002'; end if;
  if u.id = p_admin then raise exception 'You are already signed in as yourself' using errcode = '22023'; end if;
  if u.status <> 'active' then raise exception 'That account is not active' using errcode = '23514'; end if;
  v_p := app.person_portals(p_target);
  case p_portal
  when 'account' then
    if not (v_p ->> 'renter')::boolean then raise exception '% has no renter account', u.full_name using errcode = '23514'; end if;
    v_fn := null;
  when 'owner' then
    if not (v_p ->> 'owner')::boolean then raise exception '% is not an owner', u.full_name using errcode = '23514'; end if;
    v_fn := null;
  when 'investor' then
    if not (v_p ->> 'investor')::boolean then raise exception '% is not an investor', u.full_name using errcode = '23514'; end if;
    v_fn := null;
  when 'field' then
    if not (v_p ->> 'field')::boolean then raise exception '% is not field staff', u.full_name using errcode = '23514'; end if;
    v_fn := null;
  when 'va' then
    if jsonb_array_length(v_p -> 'va_functions') = 0 then raise exception '% is not an assistant', u.full_name using errcode = '23514'; end if;
    v_fn := coalesce(v_fn, v_p -> 'va_functions' ->> 0);
    if not (v_p -> 'va_functions') ? v_fn then raise exception '% does not work as %', u.full_name, v_fn using errcode = '23514'; end if;
  else
    raise exception 'Unknown portal %', p_portal using errcode = '22023';
  end case;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_admin, 'view_as_start', 'users', p_target::text, jsonb_build_object('portal', p_portal, 'function', v_fn, 'email', u.email));
  return jsonb_build_object('user_id', u.id, 'email', u.email, 'name', u.full_name, 'portal', p_portal, 'function', v_fn);
end $$;

create or replace function public.server_view_as_start(p_admin uuid, p_target uuid, p_portal text, p_fn text default null) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.view_as_start(p_admin, p_target, p_portal, p_fn) $$;

-- ================================================================ 2. Admin > Portals
-- Everyone with a portal (search by name or email), staff first; and the owners and investors on file without a sign-in.
create or replace function app.admin_portal_people(p_admin uuid, p_q text default null, p_limit integer default 200) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_q text := nullif(btrim(coalesce(p_q, '')), '');
  v_like text := '%' || replace(replace(replace(coalesce(nullif(btrim(coalesce(p_q, '')), ''), ''), '\', '\\'), '%', '\%'), '_', '\_') || '%';
  v_limit integer := least(greatest(coalesce(p_limit, 200), 1), 500);
begin
  perform app.assert_admin(p_admin);
  return jsonb_build_object(
    'people', coalesce((select jsonb_agg(x.j order by x.staff desc, x.holder desc, x.name) from (
        select jsonb_build_object('id', u.id, 'email', u.email, 'name', u.full_name, 'status', u.status, 'portals', app.person_portals(u.id)) as j,
               exists (select 1 from user_roles r where r.user_id = u.id and r.role in ('admin', 'va', 'field')) as staff,
               exists (select 1 from owners o where o.user_id = u.id) or exists (select 1 from investors i where i.user_id = u.id) as holder, u.full_name as name
          from users u
         where (exists (select 1 from user_roles r where r.user_id = u.id)
                or exists (select 1 from owners o where o.user_id = u.id)
                or exists (select 1 from investors i where i.user_id = u.id)
                or exists (select 1 from renters r where r.user_id = u.id))
           and (v_q is null or u.email ilike v_like or u.full_name ilike v_like)
         order by staff desc, holder desc, u.full_name
         limit v_limit) x), '[]'::jsonb),
    'limit', v_limit,
    'owners_without_account', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.legal_name, 'email', o.email) order by o.legal_name)
                                          from owners o where o.user_id is null), '[]'::jsonb),
    'investors_without_account', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'name', i.legal_name, 'email', i.email) order by i.legal_name)
                                             from investors i where i.user_id is null and i.status <> 'refused'), '[]'::jsonb));
end $$;

create or replace function public.admin_portal_people(p_admin uuid, p_q text default null, p_limit integer default 200) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.admin_portal_people(p_admin, p_q, p_limit) $$;

-- Which sign-in each owner and investor record has (the View as and password link buttons on Admin > Owners and Investors).
create or replace function app.admin_account_index(p_admin uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_admin);
  return jsonb_build_object(
    'owners', coalesce((select jsonb_object_agg(o.id, jsonb_build_object('id', u.id, 'email', u.email, 'name', u.full_name, 'status', u.status))
                          from owners o join users u on u.id = o.user_id), '{}'::jsonb),
    'investors', coalesce((select jsonb_object_agg(i.id, jsonb_build_object('id', u.id, 'email', u.email, 'name', u.full_name, 'status', u.status))
                             from investors i join users u on u.id = i.user_id), '{}'::jsonb));
end $$;

create or replace function public.admin_account_index(p_admin uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.admin_account_index(p_admin) $$;

-- ================================================================ 3. invitations into any role
-- The web app creates (or finds) the sign-in account and emails the link; this gives it its role. p: user_id, email,
-- full_name, role (admin, va, field, owner, investor), va_function and cover_functions (va), field_function (field),
-- owner_id (owner: an owner on file), investor_id (investor: an investor on file).
create or replace function app.admin_invite_account(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_user uuid := (p ->> 'user_id')::uuid;
  v_email text := lower(btrim(coalesce(p ->> 'email', '')));
  v_name text := nullif(btrim(coalesce(p ->> 'full_name', '')), '');
  v_role text := p ->> 'role';
  v_fn text := nullif(p ->> 'va_function', '');
  v_cover text[] := case when jsonb_typeof(p -> 'cover_functions') = 'array'
                         then array(select distinct x from jsonb_array_elements_text(p -> 'cover_functions') x where x <> coalesce(nullif(p ->> 'va_function', ''), '')) else '{}' end;
  v_owner owners;
  v_investor investors;
begin
  perform app.assert_admin(p_admin);
  if v_user is null then raise exception 'The sign-in account id is needed' using errcode = '22023'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a full email address' using errcode = '22023'; end if;
  if v_role is null or v_role not in ('admin', 'va', 'field', 'owner', 'investor') then raise exception 'Choose the role' using errcode = '22023'; end if;
  if exists (select 1 from users u where lower(u.email) = v_email and u.id <> v_user) then
    raise exception 'The address % is on another record. Change that record''s email first, or invite a different address', v_email using errcode = '23505';
  end if;
  if v_role = 'va' and (v_fn is null or v_fn not in ('finance', 'fleet', 'cs', 'sales')) then raise exception 'Choose the assistant''s function' using errcode = '22023'; end if;
  if v_role = 'va' and exists (select 1 from unnest(v_cover) x where x not in ('finance', 'fleet', 'cs', 'sales')) then
    raise exception 'Functions are finance, fleet, cs and sales' using errcode = '22023';
  end if;
  if v_role = 'field' and coalesce(p ->> 'field_function', '') not in ('driver', 'detailer', 'driver_detailer') then
    raise exception 'Choose the field function' using errcode = '22023';
  end if;
  if v_role = 'owner' then
    select * into v_owner from owners where id = nullif(p ->> 'owner_id', '')::uuid for update;
    if v_owner.id is null then raise exception 'Choose the owner on file' using errcode = '22023'; end if;
    if v_owner.user_id is not null and v_owner.user_id <> v_user then raise exception '% already has a sign-in', v_owner.legal_name using errcode = '23505'; end if;
    v_name := coalesce(v_name, v_owner.legal_name);
  elsif v_role = 'investor' then
    select * into v_investor from investors where id = nullif(p ->> 'investor_id', '')::uuid for update;
    if v_investor.id is null then raise exception 'Choose the investor on file' using errcode = '22023'; end if;
    if v_investor.user_id is not null and v_investor.user_id <> v_user then raise exception '% already has a sign-in', v_investor.legal_name using errcode = '23505'; end if;
    if exists (select 1 from investors i where i.user_id = v_user and i.id <> v_investor.id) then
      raise exception 'This sign-in already belongs to another investor' using errcode = '23505';
    end if;
    v_name := coalesce(v_name, v_investor.legal_name);
  end if;
  v_name := coalesce(v_name, (select nullif(u.full_name, '') from users u where u.id = v_user));
  if v_name is null then raise exception 'Enter the name' using errcode = '22023'; end if;

  insert into users (id, email, full_name, status) values (v_user, v_email, v_name, 'active')
  on conflict (id) do update set status = 'active', full_name = coalesce(nullif(users.full_name, ''), excluded.full_name);
  if v_role in ('admin', 'va', 'field', 'owner') then
    insert into user_roles (user_id, role, granted_by) values (v_user, v_role::app_role, p_admin) on conflict do nothing;
  end if;
  if v_role = 'va' then
    insert into staff_profiles (user_id, staff_type, va_function, cover_functions, started_on, is_active)
    values (v_user, 'va', v_fn::va_function, v_cover::va_function[], app.today(), true)
    on conflict (user_id) do update set staff_type = 'va', va_function = excluded.va_function, cover_functions = excluded.cover_functions,
                                        field_function = null, is_active = true, ended_on = null;
  elsif v_role = 'field' then
    insert into staff_profiles (user_id, staff_type, field_function, started_on, is_active)
    values (v_user, 'field', (p ->> 'field_function')::field_function, app.today(), true)
    on conflict (user_id) do update set staff_type = 'field', field_function = excluded.field_function, va_function = null,
                                        cover_functions = '{}', is_active = true, ended_on = null;
  elsif v_role = 'owner' then
    update owners set user_id = v_user where id = v_owner.id;
  elsif v_role = 'investor' then
    update investors set user_id = v_user where id = v_investor.id;
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_admin, 'invite_account', 'users', v_user::text,
          jsonb_build_object('role', v_role, 'email', v_email, 'va_function', v_fn, 'cover_functions', to_jsonb(v_cover),
                             'field_function', p ->> 'field_function', 'owner_id', v_owner.id, 'investor_id', v_investor.id));
  return jsonb_build_object('user_id', v_user, 'roles', app.my_roles(v_user));
end $$;

create or replace function public.admin_invite_account(p_admin uuid, p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.admin_invite_account(p_admin, p) $$;

-- The address an Admin sends a password link to (from Admin > Staff, Owners, Investors, Portals); recorded.
create or replace function app.admin_account_link(p_admin uuid, p_user uuid, p_kind text default 'password') returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  u users;
begin
  perform app.assert_admin(p_admin);
  select * into u from users where id = p_user;
  if u.id is null then raise exception 'That person is not on file' using errcode = 'P0002'; end if;
  if u.status <> 'active' then raise exception 'That account is not active. Restore it first' using errcode = '23514'; end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_admin, 'send_password_link', 'users', p_user::text, jsonb_build_object('email', u.email, 'kind', p_kind));
  return jsonb_build_object('user_id', u.id, 'email', u.email, 'name', u.full_name);
end $$;

create or replace function public.admin_account_link(p_admin uuid, p_user uuid, p_kind text default 'password') returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.admin_account_link(p_admin, p_user, p_kind) $$;

-- The id of the record that holds an address (an invitation to someone who already has a sign-in).
create or replace function public.server_user_by_email(p_email text) returns uuid
language sql stable security invoker set search_path = public, app as $$
  select u.id from users u where lower(u.email) = lower(btrim(p_email)) limit 1
$$;

-- ================================================================ 4. the live verification's accounts
-- One account per portal, made or repaired on every run: a renter, an owner, an investor, an assistant per function,
-- a field staff member and one Admin (only the address verify-admin@carmacars.ca may be an Admin). Each is on the email
-- suppression list, so no email is ever sent to them, and has no money or records.
create or replace function app.verify_accounts(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a jsonb;
  v_user uuid;
  v_email text;
  v_role text;
  v_fn text;
  v_out jsonb := '[]'::jsonb;
begin
  for a in select * from jsonb_array_elements(case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end) loop
    v_user := (a ->> 'user_id')::uuid;
    v_email := lower(btrim(a ->> 'email'));
    v_role := a ->> 'role';
    if v_email !~ '^verify-[a-z0-9-]+@carmacars\.ca$' then raise exception 'Not a verification address: %', v_email using errcode = '22023'; end if;
    if v_role not in ('renter', 'owner', 'investor', 'va_cs', 'va_finance', 'va_fleet', 'va_sales', 'field', 'admin') then
      raise exception 'Not a verification role: %', v_role using errcode = '22023';
    end if;
    if v_role = 'admin' and v_email <> 'verify-admin@carmacars.ca' then raise exception 'Only verify-admin@carmacars.ca may be the verification Admin' using errcode = '22023'; end if;
    if exists (select 1 from users u where u.email = v_email and u.id <> v_user) then raise exception 'The address % belongs to another account', v_email using errcode = '23505'; end if;
    -- never an Admin, except the one verification Admin
    if v_role <> 'admin' then delete from user_roles where user_id = v_user and role = 'admin'; end if;
    perform app.register_account(v_user, v_email, coalesce(a ->> 'name', 'Verify ' || initcap(replace(v_role, '_', ' '))), null);
    update users set status = 'active' where id = v_user and status <> 'active';
    if v_role <> 'renter' then delete from user_roles where user_id = v_user and role = 'renter'; end if;
    if v_role = 'owner' then
      insert into user_roles (user_id, role) values (v_user, 'owner') on conflict do nothing;
      if not exists (select 1 from owners where user_id = v_user) then
        insert into owners (user_id, owner_type, legal_name, status, email) values (v_user, 'individual', 'Verify Owner', 'active', v_email);
      end if;
    elsif v_role = 'investor' then
      if not exists (select 1 from investors where user_id = v_user) then
        insert into investors (user_id, legal_name, investor_type, status, email) values (v_user, 'Verify Investor', 'individual', 'active', v_email);
      end if;
      update investors set status = 'active' where user_id = v_user and status <> 'active';
    elsif v_role like 'va\_%' then
      v_fn := substr(v_role, 4);
      insert into user_roles (user_id, role) values (v_user, 'va') on conflict do nothing;
      insert into staff_profiles (user_id, staff_type, va_function, is_active) values (v_user, 'va', v_fn::va_function, true)
      on conflict (user_id) do update set staff_type = 'va', va_function = excluded.va_function, field_function = null, is_active = true, cover_functions = '{}', ended_on = null;
    elsif v_role = 'field' then
      insert into user_roles (user_id, role) values (v_user, 'field') on conflict do nothing;
      insert into staff_profiles (user_id, staff_type, field_function, is_active) values (v_user, 'field', 'driver', true)
      on conflict (user_id) do update set staff_type = 'field', field_function = coalesce(staff_profiles.field_function, 'driver'), va_function = null, is_active = true, ended_on = null;
    elsif v_role = 'admin' then
      insert into user_roles (user_id, role) values (v_user, 'admin') on conflict do nothing;
      delete from staff_profiles where user_id = v_user;
    end if;
    insert into email_suppressions (email, scope, reason, detail)
    select v_email, 'all', 'manual', 'Deploy verification account: no email is sent'
     where not exists (select 1 from email_suppressions s where s.email = v_email and s.scope = 'all' and s.lifted_at is null);
    v_out := v_out || jsonb_build_object('email', v_email, 'role', v_role, 'roles', app.my_roles(v_user));
  end loop;
  return v_out;
end $$;

-- ================================================================ 5. lighter portal frames
-- The unread count for the renter and owner frames (the frames read 100 whole notices to count them).
create or replace function public.my_unread_count() returns integer
language sql stable security invoker set search_path = public, app as $$
  select count(*)::integer from (select 1 from app.my_notifications(200, true)) n
$$;

-- The Admin rail's counts, without the dashboard's lists (every admin page drew the whole dashboard for five numbers).
create or replace function app.admin_rail_counts(p_admin uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_admin);
  return jsonb_build_object(
    'requests', (select count(*) from bookings b where b.status = 'requested'),
    'refunds', (select count(*) from refunds where status = 'pending_approval'),
    'statements', (select count(*) from owner_statements where status = 'draft'),
    'listings', (select count(*) from listing_intakes where state = 'needs_review'),
    'tolls', (select count(*) from toll_work_queue where bucket in ('needs_review', 'unmatched')));
end $$;

create or replace function public.admin_rail_counts(p_admin uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.admin_rail_counts(p_admin) $$;

-- ================================================================ privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['person_portals', 'view_as_start', 'admin_portal_people', 'admin_account_index', 'admin_invite_account',
              'admin_account_link', 'verify_accounts', 'admin_rail_counts']))
        or (n.nspname = 'public' and p.proname = any (array['server_view_as_start', 'admin_portal_people', 'admin_account_index', 'admin_invite_account',
              'admin_account_link', 'server_user_by_email', 'admin_rail_counts', 'server_verify_accounts']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
revoke all on function public.my_unread_count() from public, anon;
grant execute on function public.my_unread_count() to authenticated, service_role;

do $$ begin perform app.attach_audit(); end $$;
