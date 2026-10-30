-- 0197: one staff portal. SCHEMA_MARKER 0197.
-- The owner (October 30, 2026): "Instead of /va and /field it's just /staff, so I can give people access to different kinds
-- of staff work altogether. An in-person sales employee is definitely not a VA."
--
-- A staff member now holds any set of functions: cs, fleet, finance, sales and field (staff_profiles.functions, in the
-- order given; the first office function is the one the portal opens in). What a person may read and do comes from that
-- set: app.user_va_has(user, fns) is true when they hold any of fns; app.user_is_field when they hold field. The function
-- chosen on screen (the switcher, app.va_active_fn) still decides the rules that depend on the function being worked in
-- (Fleet sees no renter contact details in a conversation, Sales works on requests and offers, the task queue).
--
-- The older columns stay, kept in step by a trigger, so everything that reads them keeps working: staff_type ('va' when
-- the person holds an office function, else 'field'), va_function (the first office function), cover_functions (the
-- other office functions) and field_function (set exactly when field is held). Writing the older columns still works
-- too (the set is worked out from them). The roles (user_roles 'va' and 'field') follow the set.
--
-- Links: the portal is /staff (field work under /staff/field); the stored notification links and the links the
-- database writes into emails point there. The old /va and /field addresses redirect (web/next.config.ts).

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- Replace every match of a pattern in a function's definition (it must match at least once).
create function pg_temp.patch_re(p_sig regprocedure, p_pattern text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
  n text := regexp_replace(d, p_pattern, p_new, 'g');
begin
  if n = d then raise exception '0197: nothing to change in % for %', p_sig, p_pattern; end if;
  execute n;
end $$;

-- ================================================================ 1. the functions a person holds
create function app.staff_legacy_functions(p_type text, p_va text, p_cover text[], p_field text) returns text[]
language sql immutable set search_path = public, app as $$
  select coalesce(array(
    select x from unnest(case when p_type = 'va' and p_va is not null then array[p_va] else '{}'::text[] end
                         || case when p_type = 'va' then coalesce(p_cover, '{}'::text[]) else '{}'::text[] end
                         || case when p_field is not null or p_type = 'field' then array['field'] else '{}'::text[] end) with ordinality u(x, o)
     where x is not null group by x order by min(o)), '{}'::text[])
$$;

alter table staff_profiles add column functions text[] not null default '{}';
alter table staff_profiles disable trigger user;
update staff_profiles set functions = app.staff_legacy_functions(staff_type, va_function::text, cover_functions::text[], field_function::text);
alter table staff_profiles enable trigger user;
alter table staff_profiles
  add constraint staff_profiles_functions_check check (cardinality(functions) >= 1 and functions <@ array['cs', 'fleet', 'finance', 'sales', 'field']);
-- field_function is set exactly when field is held; a referral code belongs to someone doing field work
alter table staff_profiles drop constraint staff_profiles_check1;
alter table staff_profiles drop constraint staff_profiles_check2;
alter table staff_profiles add constraint staff_profiles_field_function_check check (('field' = any (functions)) = (field_function is not null));
alter table staff_profiles add constraint staff_profiles_referral_field_check check (referral_code is null or 'field' = any (functions));
comment on column staff_profiles.functions is
  'The staff functions this person holds (0197): any of cs, fleet, finance, sales, field, in the order given. The source of what they may read and do; staff_type, va_function, cover_functions and field_function follow it.';

-- Keeps the older columns in step (runs before the other row triggers: the sales mode trigger reads them).
create function app.staff_profiles_functions_sync() returns trigger
language plpgsql set search_path = public, app as $$
declare
  v_office text[];
begin
  if tg_op = 'INSERT' then
    if cardinality(new.functions) = 0 then
      new.functions := app.staff_legacy_functions(new.staff_type, new.va_function::text, new.cover_functions::text[], new.field_function::text);
    end if;
  elsif new.functions is not distinct from old.functions
        and (new.staff_type, new.va_function, new.cover_functions, new.field_function)
            is distinct from (old.staff_type, old.va_function, old.cover_functions, old.field_function) then
    -- an older writer (the cover functions, an older invitation): the set from the older columns
    new.functions := app.staff_legacy_functions(new.staff_type, new.va_function::text, new.cover_functions::text[], new.field_function::text);
  end if;
  new.functions := coalesce(array(select x from unnest(new.functions) with ordinality u(x, o) where nullif(btrim(x), '') is not null
                                   group by x order by min(o)), '{}'::text[]);
  v_office := array(select x from unnest(new.functions) with ordinality u(x, o) where x <> 'field' order by o);
  new.staff_type := case when cardinality(v_office) > 0 then 'va' else 'field' end;
  new.va_function := case when cardinality(v_office) > 0 and v_office[1] in ('cs', 'fleet', 'finance', 'sales') then v_office[1]::va_function end;
  new.cover_functions := array(select x::va_function from unnest(v_office[2:]) x where x in ('cs', 'fleet', 'finance', 'sales'));
  new.field_function := case when 'field' = any (new.functions) then coalesce(new.field_function, 'driver_detailer') end;
  -- field work taken away: the field referral code goes with it (the referrals already made keep their referrer)
  if tg_op = 'UPDATE' and 'field' = any (old.functions) and not 'field' = any (new.functions) then new.referral_code := null; end if;
  return new;
end $$;
create trigger staff_profiles_a_functions before insert or update on staff_profiles
  for each row execute function app.staff_profiles_functions_sync();

-- The roles follow the set: 'va' with an office function, 'field' with field work.
create function app.staff_profiles_roles_sync() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if tg_op = 'UPDATE' and new.functions is not distinct from old.functions then return null; end if;
  if new.functions && array['cs', 'fleet', 'finance', 'sales'] then
    insert into user_roles (user_id, role, granted_by) values (new.user_id, 'va', app.uid()) on conflict do nothing;
  elsif tg_op = 'UPDATE' then
    delete from user_roles where user_id = new.user_id and role = 'va';
  end if;
  if 'field' = any (new.functions) then
    insert into user_roles (user_id, role, granted_by) values (new.user_id, 'field', app.uid()) on conflict do nothing;
  elsif tg_op = 'UPDATE' then
    delete from user_roles where user_id = new.user_id and role = 'field';
  end if;
  return null;
end $$;
create trigger staff_profiles_roles after insert or update of functions on staff_profiles
  for each row execute function app.staff_profiles_roles_sync();
-- the people who already hold both kinds of work (none before this migration, but kept exact)
insert into user_roles (user_id, role)
select sp.user_id, 'va' from staff_profiles sp where sp.functions && array['cs', 'fleet', 'finance', 'sales'] on conflict do nothing;
insert into user_roles (user_id, role)
select sp.user_id, 'field' from staff_profiles sp where 'field' = any (sp.functions) on conflict do nothing;

-- ================================================================ 2. permissions from the set
-- The function chosen on screen when it is one the person holds (an office function), else their first office function.
create or replace function app.va_active_fn(p_user uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce(
    (select x from unnest(sp.functions) x where x <> 'field' and x = nullif(current_setting('app.va_active', true), '') limit 1),
    (select x from unnest(sp.functions) with ordinality u(x, o) where x <> 'field' order by o limit 1))
    from staff_profiles sp where sp.user_id = p_user and sp.is_active
$$;

-- True when the person holds any of the functions (with none named: any office function).
create or replace function app.user_va_has(p_user uuid, variadic p_functions text[] default '{}') returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (
    select 1 from user_roles r join users u on u.id = r.user_id
      join staff_profiles sp on sp.user_id = r.user_id and sp.is_active
     where r.user_id = p_user and r.role = 'va' and u.status = 'active'
       and sp.functions && case when cardinality(p_functions) = 0 then array['cs', 'fleet', 'finance', 'sales'] else p_functions end)
    or (p_user is not null and 'cs' = any (p_functions) and coalesce(current_setting('app.field_as_cs', true), '') = p_user::text)
$$;

create or replace function app.va_has(variadic p_functions text[] default '{}') returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.has_role('va') and exists (
    select 1 from staff_profiles sp
     where sp.user_id = app.uid() and sp.is_active
       and sp.functions && case when cardinality(p_functions) = 0 then array['cs', 'fleet', 'finance', 'sales'] else p_functions end)
     and app.staff_two_step_ok()
$$;

create or replace function app.user_is_field(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (
    select 1 from user_roles r join users u on u.id = r.user_id
      join staff_profiles sp on sp.user_id = r.user_id and 'field' = any (sp.functions) and sp.is_active
     where r.user_id = p_user and r.role = 'field' and u.status = 'active')
    or (p_user is not null and coalesce(current_setting('app.handover_as', true), '') = p_user::text)
$$;

create or replace function app.is_field() returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.has_role('field') and exists (
    select 1 from staff_profiles sp where sp.user_id = app.uid() and 'field' = any (sp.functions) and sp.is_active)
     and app.staff_two_step_ok()
$$;

-- Holding Sales narrows two reads to the Sales view; that now follows the function worked in, so a person who also
-- holds customer service keeps the full view there.
select pg_temp.patch_re('app.va_read(uuid, text, jsonb)'::regprocedure,
  $p$p_what = 'verification' and app\.user_va_has\(p_user, 'sales'\)$p$, $n$p_what = 'verification' and app.va_active_fn(p_user) = 'sales'$n$);
select pg_temp.patch_re('app.va_do(uuid, text, jsonb)'::regprocedure,
  $p$p_action = 'verify_upload' and app\.user_va_has\(p_user, 'sales'\)$p$, $n$p_action = 'verify_upload' and app.va_active_fn(p_user) = 'sales'$n$);

-- Field work and Sales, read from the set wherever the older columns stood for them.
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname <> all (array['admin_invite_account', 'verify_accounts', 'staff_profiles_functions_sync', 'user_is_field', 'is_field'])
       and p.prosrc ~ $r$staff_type\s*=\s*'field'|staff_type\s*(=|<>)\s*'va'\s*(and|or)\s*(sp\.|new\.)?va_function(::text)?\s*(=|<>)\s*'sales'$r$
  loop
    perform pg_temp.patch_re(f.sig, $p$(sp\.|new\.)staff_type = 'va' and (sp\.|new\.)va_function(::text)? = 'sales'$p$, $n$'sales' = any (\1functions)$n$)
      where pg_get_functiondef(f.sig) ~ $p$(sp\.|new\.)staff_type = 'va' and (sp\.|new\.)va_function(::text)? = 'sales'$p$;
    perform pg_temp.patch_re(f.sig, $p$sp\.staff_type <> 'va' or sp\.va_function::text <> 'sales'$p$, $n$not ('sales' = any (sp.functions))$n$)
      where pg_get_functiondef(f.sig) ~ $p$sp\.staff_type <> 'va' or sp\.va_function::text <> 'sales'$p$;
    perform pg_temp.patch_re(f.sig, $p$([a-z_]+\.)?staff_type = 'field'$p$, $n$'field' = any (\1functions)$n$)
      where pg_get_functiondef(f.sig) ~ $p$staff_type = 'field'$p$;
  end loop;
end $$;

-- (the staff list of the commissions screen groups by the profile: the set joins the grouping)
select pg_temp.patch_re('app.commission_admin_pre0174(uuid, jsonb)'::regprocedure, $p$sp\.staff_type, sp\.commission_bps\)$p$, $n$sp.staff_type, sp.functions, sp.commission_bps)$n$);

-- ================================================================ 3. what the frame reads
-- my_roles: every function held (field included) and the Sales work mode, for the staff portal's one navigation.
alter function app.my_roles(uuid) rename to my_roles_pre0197;
create function app.my_roles(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.my_roles_pre0197(p_user) || jsonb_build_object(
    'functions', coalesce((select to_jsonb(sp.functions) from staff_profiles sp join users u on u.id = sp.user_id and u.status = 'active'
                            where sp.user_id = p_user and sp.is_active
                              and exists (select 1 from user_roles r where r.user_id = sp.user_id and r.role in ('va', 'field'))), '[]'::jsonb),
    'sales_work_mode', (select sp.sales_work_mode from staff_profiles sp where sp.user_id = p_user and sp.is_active and 'sales' = any (sp.functions)))
$$;
select pg_temp.copy_grants('app.my_roles(uuid)'::regprocedure, 'app.my_roles_pre0197(uuid)'::regprocedure);

-- Admin > Portals: the set as well
alter function app.person_portals(uuid) rename to person_portals_pre0197;
create function app.person_portals(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.person_portals_pre0197(p_user) || jsonb_build_object(
    'functions', coalesce((select to_jsonb(sp.functions) from staff_profiles sp join users u on u.id = sp.user_id and u.status = 'active'
                            where sp.user_id = p_user and sp.is_active), '[]'::jsonb))
$$;
select pg_temp.copy_grants('app.person_portals(uuid)'::regprocedure, 'app.person_portals_pre0197(uuid)'::regprocedure);

-- ================================================================ 4. setting a person's functions
-- Admin > Staff: the functions (checkboxes), the Sales work mode and the field role. At least one function.
create function app.staff_set_functions(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_user uuid := nullif(p ->> 'user_id', '')::uuid;
  sp staff_profiles;
  v_fns text[] := case when jsonb_typeof(p -> 'functions') = 'array'
                       then array(select x from jsonb_array_elements_text(p -> 'functions') with ordinality u(x, o) where nullif(btrim(x), '') is not null group by x order by min(o))
                       else null end;
  v_field text := nullif(p ->> 'field_function', '');
  v_mode text := nullif(p ->> 'sales_work_mode', '');
begin
  perform app.assert_admin(p_admin);
  select * into sp from staff_profiles where user_id = v_user for update;
  if sp.user_id is null then raise exception 'Choose a staff member' using errcode = '22023'; end if;
  if v_fns is null or cardinality(v_fns) = 0 then raise exception 'Choose at least one function' using errcode = '22023'; end if;
  if not v_fns <@ array['cs', 'fleet', 'finance', 'sales', 'field'] then
    raise exception 'Functions are customer service, fleet, finance, sales and field work' using errcode = '22023';
  end if;
  if v_field is not null and v_field not in ('driver', 'detailer', 'driver_detailer') then raise exception 'Choose the field role' using errcode = '22023'; end if;
  if v_mode is not null and v_mode not in ('in_person', 'remote') then raise exception 'Choose in person or remote' using errcode = '22023'; end if;
  update staff_profiles
     set functions = v_fns,
         field_function = case when 'field' = any (v_fns) then coalesce(v_field::field_function, sp.field_function, 'driver_detailer') end
   where user_id = v_user;
  if 'sales' = any (v_fns) and v_mode is not null then
    perform app.staff_set_sales_mode(p_admin, v_user, v_mode, 'Set with the functions');
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_admin, 'staff_functions_set', 'staff_profiles', v_user::text,
          jsonb_build_object('functions', to_jsonb(sp.functions), 'field_function', sp.field_function, 'sales_work_mode', sp.sales_work_mode),
          (select jsonb_build_object('functions', to_jsonb(x.functions), 'field_function', x.field_function, 'sales_work_mode', x.sales_work_mode)
             from staff_profiles x where x.user_id = v_user));
  return (select jsonb_build_object('user_id', x.user_id, 'functions', to_jsonb(x.functions), 'field_function', x.field_function, 'sales_work_mode', x.sales_work_mode)
            from staff_profiles x where x.user_id = v_user);
end $$;

-- The invitation (and the hire): role 'staff' with the functions; 'va' and 'field' as before.
create or replace function app.admin_invite_account(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_user uuid := (p ->> 'user_id')::uuid;
  v_email text := lower(btrim(coalesce(p ->> 'email', '')));
  v_name text := nullif(btrim(coalesce(p ->> 'full_name', '')), '');
  v_role text := p ->> 'role';
  v_fn text := nullif(p ->> 'va_function', '');
  v_fns text[];
  v_field text := nullif(p ->> 'field_function', '');
  v_mode text := nullif(coalesce(p ->> 'sales_work_mode', p ->> 'work_mode'), '');
  v_owner owners;
  v_investor investors;
begin
  perform app.assert_admin(p_admin);
  if v_user is null then raise exception 'The sign-in account id is needed' using errcode = '22023'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a full email address' using errcode = '22023'; end if;
  if v_role is null or v_role not in ('admin', 'staff', 'va', 'field', 'owner', 'investor') then raise exception 'Choose the role' using errcode = '22023'; end if;
  if exists (select 1 from users u where lower(u.email) = v_email and u.id <> v_user) then
    raise exception 'The address % is on another record. Change that record''s email first, or invite a different address', v_email using errcode = '23505';
  end if;
  -- the functions: the list given, or the older shape (one function and its cover, or field work)
  if v_role = 'staff' then
    v_fns := case when jsonb_typeof(p -> 'functions') = 'array'
                  then array(select x from jsonb_array_elements_text(p -> 'functions') with ordinality u(x, o) where nullif(btrim(x), '') is not null group by x order by min(o)) end;
  elsif v_role = 'va' then
    if v_fn is null or v_fn not in ('finance', 'fleet', 'cs', 'sales') then raise exception 'Choose the assistant''s function' using errcode = '22023'; end if;
    v_fns := array(select x from unnest(array[v_fn] || case when jsonb_typeof(p -> 'cover_functions') = 'array'
                                                          then array(select jsonb_array_elements_text(p -> 'cover_functions')) else '{}'::text[] end) with ordinality u(x, o)
                    where nullif(btrim(x), '') is not null group by x order by min(o));
  elsif v_role = 'field' then
    v_fns := array['field'];
  end if;
  if v_role in ('staff', 'va', 'field') then
    if v_fns is null or cardinality(v_fns) = 0 then raise exception 'Choose at least one function' using errcode = '22023'; end if;
    if not v_fns <@ array['cs', 'fleet', 'finance', 'sales', 'field'] then
      raise exception 'Functions are customer service, fleet, finance, sales and field work' using errcode = '22023';
    end if;
    if 'field' = any (v_fns) and coalesce(v_field, case when v_role = 'staff' then 'driver_detailer' end, '') not in ('driver', 'detailer', 'driver_detailer') then
      raise exception 'Choose the field function' using errcode = '22023';
    end if;
    if v_mode is not null and v_mode not in ('in_person', 'remote') then raise exception 'Choose in person or remote' using errcode = '22023'; end if;
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
  if v_role in ('admin', 'owner') then
    insert into user_roles (user_id, role, granted_by) values (v_user, v_role::app_role, p_admin) on conflict do nothing;
  end if;
  if v_role in ('staff', 'va', 'field') then
    -- the roles follow the functions (app.staff_profiles_roles_sync); a new profile adds them, an existing one is changed
    insert into staff_profiles (user_id, staff_type, functions, field_function, started_on, is_active)
    values (v_user, case when v_fns && array['cs', 'fleet', 'finance', 'sales'] then 'va' else 'field' end, v_fns,
            case when 'field' = any (v_fns) then coalesce(v_field, 'driver_detailer')::field_function end, app.today(), true)
    on conflict (user_id) do update set functions = excluded.functions, field_function = excluded.field_function, is_active = true, ended_on = null;
    if v_fns && array['cs', 'fleet', 'finance', 'sales'] then
      insert into user_roles (user_id, role, granted_by) values (v_user, 'va', p_admin) on conflict do nothing;
    end if;
    if 'field' = any (v_fns) then
      insert into user_roles (user_id, role, granted_by) values (v_user, 'field', p_admin) on conflict do nothing;
    end if;
    if 'sales' = any (v_fns) and v_mode is not null then
      perform app.staff_set_sales_mode(p_admin, v_user, v_mode, 'Set at the invitation');
    end if;
  elsif v_role = 'owner' then
    update owners set user_id = v_user where id = v_owner.id;
  elsif v_role = 'investor' then
    update investors set user_id = v_user where id = v_investor.id;
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_admin, 'invite_account', 'users', v_user::text,
          jsonb_build_object('role', v_role, 'email', v_email, 'functions', to_jsonb(v_fns), 'field_function', v_field,
                             'sales_work_mode', v_mode, 'owner_id', v_owner.id, 'investor_id', v_investor.id));
  return jsonb_build_object('user_id', v_user, 'roles', app.my_roles(v_user));
end $$;

-- ================================================================ 5. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0197;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_do' and p_name = 'staff_functions' then
    perform app.door_begin(p_user, p_aal);
    return app.staff_set_functions(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre0197(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0197(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 6. links
-- The stored notification links: the portal's own pages under /staff (the old /va/<function>/... shapes resolved).
create function pg_temp.staff_link(p text) returns text language sql immutable as $$
  select case
    when p is null then null
    when p ~ '^/va/cs/bookings/[^/]+/identity$' then regexp_replace(p, '^/va/cs/bookings/([^/]+)/identity$', '/staff/verify/\1')
    when p ~ '^/va/(cs|finance|fleet|sales)/bookings/' then regexp_replace(p, '^/va/(cs|finance|fleet|sales)/bookings/', '/staff/bookings/')
    when p ~ '^/va/finance/tolls-tickets/' then regexp_replace(p, '^/va/finance/tolls-tickets/', '/staff/tolls?ticket=')
    when p ~ '^/va/finance/(owner|insurer)-invoices/' then '/staff/money'
    when p ~ '^/va/fleet/listings/' then regexp_replace(p, '^/va/fleet/listings/', '/staff/listings/')
    when p = '/va/fleet/expiries' then '/staff/fleet#expiry'
    when p ~ '^/va/fleet/vehicles/' then regexp_replace(p, '^/va/fleet/vehicles/', '/staff/vehicles/')
    when p ~ '^/va/sales/applications/' then regexp_replace(p, '^/va/sales/applications/', '/staff/leads?application=')
    when p = '/va/cs/reviews' or p ~ '^/va/(cs|finance|sales)$' then '/staff'
    when p ~ '^/va(/|$)' then regexp_replace(p, '^/va', '/staff')
    when p ~ '^/field(/|$)' then regexp_replace(p, '^/field', '/staff/field')
    else p end
$$;
update notification_catalogue set link_path = pg_temp.staff_link(link_path) where link_path ~ '^/(va|field)(/|$)';
update notification_link_paths set path = pg_temp.staff_link(path) where path ~ '^/(va|field)(/|$)';
-- the guides' sign-in addresses and names
update guides set signin_url = replace(signin_url, 'next=/va', 'next=/staff'), title = 'Staff Guide' where portal = 'va';
update guides set signin_url = replace(signin_url, 'next=/field', 'next=/staff/field') where portal = 'field';

-- The links the database writes into emails and digests.
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.prosrc ~ $r$'/(va|field)[/']$r$ and p.proname <> 'staff_link'
  loop
    perform pg_temp.patch_re(f.sig, $p$'/va/$p$, $n$'/staff/$n$) where pg_get_functiondef(f.sig) ~ $p$'/va/$p$;
    perform pg_temp.patch_re(f.sig, $p$'/va'$p$, $n$'/staff'$n$) where pg_get_functiondef(f.sig) ~ $p$'/va'$p$;
    perform pg_temp.patch_re(f.sig, $p$'/field/$p$, $n$'/staff/field/$n$) where pg_get_functiondef(f.sig) ~ $p$'/field/$p$;
    perform pg_temp.patch_re(f.sig, $p$'/field'$p$, $n$'/staff/field'$n$) where pg_get_functiondef(f.sig) ~ $p$'/field'$p$;
  end loop;
end $$;

-- ================================================================ 7. privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['staff_legacy_functions', 'staff_profiles_functions_sync', 'staff_profiles_roles_sync',
             'staff_set_functions', 'my_roles_pre0197', 'person_portals_pre0197', 'door_pre0197'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
