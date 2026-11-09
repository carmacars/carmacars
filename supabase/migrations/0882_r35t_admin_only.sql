-- 0882: an Admin is only an Admin (Release 35, part T; docs/changes/2026-11-08-r35-field-assign-gate.md). No applied migration is
-- edited. An Admin already has every staff page (the field jobs board is Cars > Field jobs, an Admin can be given a job, and the
-- field portal opens for the jobs they hold), so a staff role on an Admin account (given as a stopgap) is taken off, and none can be
-- added again: the Portals invite form and Staff and roles are refused by the database. The renter role (and owner or investor) stays.
set local check_function_bodies = off;

-- Takes the office and field roles and the staff profile off every Admin; audited, with what they held.
create function app.admin_staff_roles_clean() returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  n integer := 0;
begin
  for r in
    select u.id as user_id,
           (select coalesce(array_agg(x.role::text order by x.role::text), '{}') from user_roles x where x.user_id = u.id and x.role in ('va', 'field')) as roles,
           (select sp.functions from staff_profiles sp where sp.user_id = u.id) as functions
      from users u
     where exists (select 1 from user_roles a where a.user_id = u.id and a.role = 'admin')
       and (exists (select 1 from user_roles x where x.user_id = u.id and x.role in ('va', 'field')) or exists (select 1 from staff_profiles sp where sp.user_id = u.id))
  loop
    insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
    values (null, 'admin_staff_roles_removed', 'users', r.user_id::text, jsonb_build_object('roles', to_jsonb(r.roles), 'functions', to_jsonb(r.functions)), jsonb_build_object('reason', 'An Admin already has every staff page'));
    delete from staff_profiles where user_id = r.user_id;
    delete from user_roles where user_id = r.user_id and role in ('va', 'field');
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function app.admin_staff_roles_clean() from public, anon, authenticated;
grant execute on function app.admin_staff_roles_clean() to service_role;

select app.admin_staff_roles_clean();

-- the refusal, whoever writes (the invite form, Staff and roles, a hire)
create function app.admin_no_staff_role() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if tg_table_name = 'user_roles' then
    if new.role::text not in ('va', 'field') then return new; end if;
  end if;
  if exists (select 1 from user_roles a where a.user_id = new.user_id and a.role = 'admin') then
    raise exception 'An Admin already has every staff page: no staff role is added to an Admin account' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger user_roles_admin_no_staff before insert on user_roles for each row execute function app.admin_no_staff_role();
create trigger staff_profiles_admin_no_staff before insert or update on staff_profiles for each row execute function app.admin_no_staff_role();
