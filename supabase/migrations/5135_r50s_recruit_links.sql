-- 5135 (R50 hotfix 2, Sales; docs/changes/2026-11-27-r50-sales-fixes.md). The owner, Nov 27: "in-person salespeople can
-- refer recruits: an invite link that makes the recruit apply and do the interview; recruits are tracked under the referrer".
--
-- 1. The link: each in-person salesperson (the Sales function and in-person mode, or field staff with Sales) makes their
--    own invite link once (va_do recruit_link): staff_profiles.recruit_code, 8 random letters and digits. The link opens the
--    application of the in-person Sales role (carmacars.ca/careers/<slug>/apply?by=<code>&src=referral): the recruit applies,
--    is screened and books the interview like every candidate (0173). Nothing is skipped.
-- 2. The credit: the application made from the link keeps job_applications.recruited_by (public.server_hiring_apply wraps
--    the 0173/1067 flow and sets it after the application is saved; a code nobody holds, or one of a person no longer
--    active, is ignored; nobody recruits themselves). The referrer is told when the recruit applies (recruit_applied) and
--    when they are hired (recruit_hired). Admin sees "Recruited by" on the application (admin_read hiring_application).
-- 3. Tracking: va_read my_recruits: the link, and each recruit with their first name, the role, when they applied and where
--    they are (applied, interview booked, interviewed, hired, not hired), nothing else about them.
-- SCHEMA_MARKER is not changed. No applied migration is edited: public.server_hiring_apply, app.hiring_application_read and
-- app.door are wrapped (_pre5135).
set local check_function_bodies = off;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

alter table staff_profiles add column if not exists recruit_code text unique check (recruit_code is null or recruit_code ~ '^[a-z0-9]{8}$');
comment on column staff_profiles.recruit_code is 'The in-person salesperson''s recruit invite code (5135): /careers/<in-person Sales role>/apply?by=<code>.';
alter table job_applications add column if not exists recruited_by uuid references users (id);
create index if not exists job_applications_recruited_by_idx on job_applications (recruited_by, created_at) where recruited_by is not null;
comment on column job_applications.recruited_by is 'The in-person salesperson whose invite link the candidate applied from (5135).';

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort, pref_type) values
  ('recruit_applied', 'Someone applied from your invite link', 'Hiring', '{assigned}', 'normal', 'requests', true, false,
   '5135: a recruit you invited applied; My recruits shows where they are.', 60, 'staff_system'),
  ('recruit_hired', 'Someone you recruited was hired', 'Hiring', '{assigned}', 'normal', 'requests', true, false,
   '5135: a recruit you invited was hired.', 61, 'staff_system')
on conflict (rule) do nothing;

create function app.can_recruit(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select p_user is not null and app.user_va_has_sales(p_user)
     and exists (select 1 from staff_profiles sp where sp.user_id = p_user and (sp.sales_work_mode = 'in_person' or sp.staff_type = 'field' or 'field' = any (sp.functions)))
$$;

create function app.recruit_role_slug() returns text
language sql stable security definer set search_path = public, app, pg_temp as $$
  select r.slug from hiring_roles r where r.active and r.va_function::text = 'sales' and not r.remote and coalesce(r.work_mode, 'in_person') <> 'remote'
   order by r.sort_order, r.slug limit 1
$$;

create function app.recruit_status_words(p_status text) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select case p_status when 'hired' then 'Hired' when 'booked' then 'Interview booked' when 'interviewed' then 'Interviewed'
                      when 'invited' then 'Invited to book an interview' when 'referred' then 'Offered another role'
                      when 'declined' then 'Not a fit' when 'rejected' then 'Not hired' when 'no_show' then 'Missed the interview'
                      when 'withdrawn' then 'Withdrew' when 'below_bar' then 'Waiting for review' else 'Applied' end
$$;

create function app.recruit_link_json(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('code', sp.recruit_code, 'role', app.recruit_role_slug(),
    'link', case when sp.recruit_code is not null then rtrim((app.settings()).notify_base_url, '/') || '/careers/' || coalesce(app.recruit_role_slug() || '/apply', '')
                                                       || '?by=' || sp.recruit_code || '&src=referral' end)
    from staff_profiles sp where sp.user_id = p_user
$$;

create function app.recruit_link(p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v text;
begin
  if not app.can_recruit(p_by) then raise exception 'Invite links are for in-person salespeople' using errcode = '42501'; end if;
  if (select recruit_code from staff_profiles where user_id = p_by) is null then
    loop
      v := substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
      exit when v ~ '^[a-z0-9]{8}$' and not exists (select 1 from staff_profiles where recruit_code = v);
    end loop;
    update staff_profiles set recruit_code = v where user_id = p_by;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'recruit_link', 'staff_profiles', p_by::text, jsonb_build_object('code', v));
  end if;
  return app.recruit_link_json(p_by);
end $$;

create function app.my_recruits(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  if not (app.can_recruit(p_by) or exists (select 1 from job_applications a where a.recruited_by = p_by)) then
    raise exception 'My recruits is for in-person salespeople' using errcode = '42501';
  end if;
  return coalesce(app.recruit_link_json(p_by), '{}'::jsonb) || jsonb_build_object('can_invite', app.can_recruit(p_by),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', split_part(btrim(coalesce(a.full_name, '')), ' ', 1), 'role', r.short_title,
               'applied_at', a.created_at, 'status', a.status, 'words', app.recruit_status_words(a.status), 'hired', a.status = 'hired') order by a.created_at desc)
             from job_applications a join hiring_roles r on r.id = a.role_id where a.recruited_by = p_by and a.purged_at is null), '[]'::jsonb));
end $$;

-- ================================================================ the application from the link
alter function public.server_hiring_apply(jsonb, text) rename to server_hiring_apply_pre5135;
create function public.server_hiring_apply(p jsonb, p_ip text default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v jsonb := public.server_hiring_apply_pre5135(p, p_ip);
  v_code text := lower(nullif(btrim(coalesce(p ->> 'by', '')), ''));
  v_ref uuid;
  a job_applications;
begin
  if v_code is null or v_code !~ '^[a-z0-9]{8}$' or not coalesce((v ->> 'ok')::boolean, false) then return v; end if;
  select sp.user_id into v_ref from staff_profiles sp join users u on u.id = sp.user_id
   where sp.recruit_code = v_code and sp.is_active and u.status = 'active';
  if v_ref is null or not app.can_recruit(v_ref) then return v; end if;
  select x.* into a from job_applications x join hiring_roles r on r.id = x.role_id
   where lower(x.email) = lower(btrim(coalesce(p ->> 'email', ''))) and r.slug = p ->> 'role' and x.recruited_by is null
     and x.created_at > now() - interval '10 minutes'
   order by x.created_at desc limit 1;
  if a.id is null or exists (select 1 from users u where u.id = v_ref and lower(u.email) = lower(a.email)) then return v; end if;
  update job_applications set recruited_by = v_ref where id = a.id;
  begin
    perform app.staff_alert('recruit_applied', 'job_application', a.id, 'applied',
      left(format('%s applied from your invite link', coalesce(nullif(split_part(btrim(coalesce(a.full_name, '')), ' ', 1), ''), 'Someone')), 140),
      'They are screened and book their interview like every candidate. My recruits shows where they are.',
      jsonb_build_object('assigned_to', v_ref, 'path_staff', '/staff/recruits'));
  exception when others then raise warning 'recruit alert not sent for %: %', a.id, sqlerrm;
  end;
  return v;
end $$;
select pg_temp.copy_grants('public.server_hiring_apply(jsonb, text)'::regprocedure, 'public.server_hiring_apply_pre5135(jsonb, text)'::regprocedure);

create function app.recruit_hired_trg() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if new.status = 'hired' and old.status is distinct from 'hired' then
    perform app.staff_alert('recruit_hired', 'job_application', new.id, 'hired',
      left(format('%s, whom you recruited, was hired', coalesce(nullif(split_part(btrim(coalesce(new.full_name, '')), ' ', 1), ''), 'Someone')), 140),
      'Welcome them to the team. My recruits shows everyone you invited.', jsonb_build_object('assigned_to', new.recruited_by, 'path_staff', '/staff/recruits'));
  end if;
  return null;
exception when others then
  raise warning 'recruit hired alert not sent for %: %', new.id, sqlerrm;
  return null;
end $$;
create trigger job_applications_zz_recruit_hired after update of status on job_applications
  for each row when (new.recruited_by is not null) execute function app.recruit_hired_trg();

alter function app.hiring_application_read(uuid, jsonb) rename to hiring_application_read_pre5135;
create function app.hiring_application_read(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v jsonb := app.hiring_application_read_pre5135(p_by, p);
begin
  if jsonb_typeof(v) = 'object' then
    v := v || jsonb_build_object('recruited_by', (select coalesce(u.full_name, u.email) from job_applications a join users u on u.id = a.recruited_by
                                                   where a.id = nullif(p ->> 'id', '')::uuid));
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.hiring_application_read(uuid, jsonb)'::regprocedure, 'app.hiring_application_read_pre5135(uuid, jsonb)'::regprocedure);

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre5135;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if (p_call in ('va_read', 'ops_read', 'field_read') and p_name = 'my_recruits') or (p_call in ('va_do', 'ops_do', 'field_do') and p_name = 'recruit_link') then
    perform app.door_begin(p_user, p_aal);
    if p_name = 'my_recruits' then return app.my_recruits(p_user); end if;
    return app.recruit_link(p_user);
  end if;
  return app.door_pre5135(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre5135(uuid, text, text, text, jsonb)'::regprocedure);

revoke all on function app.can_recruit(uuid), app.recruit_role_slug(), app.recruit_status_words(text), app.recruit_link_json(uuid), app.recruit_link(uuid),
  app.my_recruits(uuid), app.recruit_hired_trg() from public, anon, authenticated;
grant execute on function app.can_recruit(uuid), app.recruit_role_slug(), app.recruit_status_words(text), app.recruit_link_json(uuid), app.recruit_link(uuid),
  app.my_recruits(uuid), app.recruit_hired_trg() to service_role;
