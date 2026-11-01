-- 0343: verification and test accounts never get real leads, owners or tasks (Release 26, docs/changes/2026-11-06-sales-owner-recruitment.md).
-- On production two website owner leads (October 27 and 28) were given to "Verify Invitation" and "Verify Sales", the
-- accounts the live verification signs in with, and both said "Follow-ups stopped: On file before the automatic
-- follow-ups": nobody followed them up.
--   1. One test for a test account (app.staff_is_test, 0078, widened): an address verify-...@carmacars.ca, an address of
--      site_settings.admin_test_emails, the live verification's invitation addresses (...verify-...@ any domain, and the
--      test inbox resend.dev). app.email_is_test says the same of an address.
--   2. Never picked: a lead given to a test account when it comes in goes to the least busy real Sales person, or to nobody
--      (leads_no_test_staff); a test account is never "sourced by" on a real lead, owner or application, nor assigned a task
--      about a real lead or owner (owners_no_test_staff, owner_applications_no_test_staff, tasks_no_test_staff). A lead,
--      owner or application that is itself a test one (a test address, owners.is_test) keeps its test account.
--      app.owner_sales_credit credits no test account.
--   3. Clean-up now (app.clear_test_account_credit): real leads, owners, applications and open tasks held by a test
--      account become unassigned; a test account's commission request on a real owner is removed.
--   4. The owner leads on file before the automatic follow-ups (0217) that nobody moved get an Admin task "Follow up now"
--      (app.owner_leads_follow_up_now), instead of staying silently stopped.
-- SCHEMA_MARKER 0343. No applied migration is edited.
set local check_function_bodies = off;

-- ================================================================ 1. what a test account is
create or replace function app.email_is_test(p_email text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce(lower(btrim(p_email)) like 'verify-%@carmacars.ca'
              or lower(btrim(p_email)) like '%+verify-%@%'
              or lower(btrim(p_email)) like '%@resend.dev'
              or lower(btrim(p_email)) = any (select lower(x) from site_settings s, unnest(s.admin_test_emails) x where s.singleton), false)
$$;

create or replace function app.staff_is_test(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select app.email_is_test(u.email) from users u where u.id = p_user), false)
$$;

-- The least busy real Sales person for a new owner lead (0022's rule, test accounts left out); nobody when there is none.
create or replace function app.lead_real_assignee() returns uuid
language sql stable security definer set search_path = public, app as $$
  select sp.user_id
    from staff_profiles sp join users u on u.id = sp.user_id and u.status = 'active'
    join user_roles r on r.user_id = sp.user_id and r.role = 'va'
   where sp.staff_type = 'va' and sp.va_function = 'sales' and sp.is_active and not app.staff_is_test(sp.user_id)
   order by (select count(*) from leads l where l.assigned_to = sp.user_id and l.status in ('new', 'contacted', 'qualified')), sp.created_at, sp.user_id
   limit 1
$$;

-- ================================================================ 2. never picked
create or replace function app.leads_no_test_staff() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if app.email_is_test(new.email) then return new; end if;
  if new.assigned_to is not null and app.staff_is_test(new.assigned_to) and (tg_op = 'INSERT' or new.assigned_to is distinct from old.assigned_to) then
    new.assigned_to := case when tg_op = 'INSERT' and new.kind = 'owner_program' then app.lead_real_assignee() end;
  end if;
  if new.sourced_by is not null and app.staff_is_test(new.sourced_by) then new.sourced_by := null; end if;
  return new;
end $$;
drop trigger if exists leads_no_test_staff on leads;
create trigger leads_no_test_staff before insert or update of assigned_to, sourced_by on leads for each row execute function app.leads_no_test_staff();

create or replace function app.owners_no_test_staff() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if not coalesce(new.is_test, false) and not app.email_is_test(new.email) and new.recruited_by is not null and app.staff_is_test(new.recruited_by) then
    new.recruited_by := null; new.recruited_at := null; new.recruited_via := null;
  end if;
  return new;
end $$;
drop trigger if exists owners_no_test_staff on owners;
create trigger owners_no_test_staff before insert or update of recruited_by on owners for each row execute function app.owners_no_test_staff();

create or replace function app.owner_applications_no_test_staff() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.sourced_by is not null and app.staff_is_test(new.sourced_by)
     and not exists (select 1 from owners o where o.id = new.owner_id and (o.is_test or app.email_is_test(o.email))) then
    new.sourced_by := null;
  end if;
  return new;
end $$;
drop trigger if exists owner_applications_no_test_staff on owner_applications;
create trigger owner_applications_no_test_staff before insert or update of sourced_by on owner_applications for each row execute function app.owner_applications_no_test_staff();

-- a task about a real lead or a real owner is never given to a test account (it stays in its queue, unassigned)
create or replace function app.task_is_real(t tasks) returns boolean
language sql stable security definer set search_path = public, app as $$
  select (t.owner_id is not null and exists (select 1 from owners o where o.id = t.owner_id and not o.is_test and not app.email_is_test(o.email)))
      or (t.related_table = 'leads' and exists (select 1 from leads l where l.id = t.related_id and not app.email_is_test(l.email)))
      or (t.related_table = 'owner_applications' and exists (select 1 from owner_applications a join owners o on o.id = a.owner_id
                                                             where a.id = t.related_id and not o.is_test and not app.email_is_test(o.email)))
$$;
create or replace function app.tasks_no_test_staff() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.assigned_to is not null and app.staff_is_test(new.assigned_to) and app.task_is_real(new) then new.assigned_to := null; end if;
  return new;
end $$;
drop trigger if exists tasks_no_test_staff on tasks;
create trigger tasks_no_test_staff before insert or update of assigned_to on tasks for each row execute function app.tasks_no_test_staff();

-- 0340's credit: never a test account
alter function app.owner_sales_credit(uuid, uuid, uuid, text) rename to owner_sales_credit_pre0343;
create function app.owner_sales_credit(p_application uuid, p_staff uuid, p_lead uuid, p_via text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if app.staff_is_test(p_staff) and not exists (select 1 from owner_applications a join owners o on o.id = a.owner_id
                                                 where a.id = p_application and (o.is_test or app.email_is_test(o.email))) then
    return jsonb_build_object('credited', false, 'reason', 'a test account');
  end if;
  return app.owner_sales_credit_pre0343(p_application, p_staff, p_lead, p_via);
end $$;

-- ================================================================ 3. clean-up of what is on file
create or replace function app.clear_test_account_credit() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  n_leads integer; n_src integer; n_owners integer; n_apps integer; n_tasks integer; n_req integer;
begin
  update leads set assigned_to = null, updated_at = now()
   where assigned_to is not null and app.staff_is_test(assigned_to) and not app.email_is_test(email);
  get diagnostics n_leads = row_count;
  update leads set sourced_by = null, updated_at = now()
   where sourced_by is not null and app.staff_is_test(sourced_by) and not app.email_is_test(email);
  get diagnostics n_src = row_count;
  delete from owner_recruit_requests r using owners o
   where o.id = r.owner_id and app.staff_is_test(r.staff_id) and not o.is_test and not app.email_is_test(o.email)
     and not exists (select 1 from staff_commissions c where c.owner_recruit_request_id = r.id);
  get diagnostics n_req = row_count;
  update owners set recruited_by = null, recruited_at = null, recruited_via = null
   where recruited_by is not null and app.staff_is_test(recruited_by) and not is_test and not app.email_is_test(email);
  get diagnostics n_owners = row_count;
  update owner_applications a set sourced_by = null
   where a.sourced_by is not null and app.staff_is_test(a.sourced_by)
     and exists (select 1 from owners o where o.id = a.owner_id and not o.is_test and not app.email_is_test(o.email));
  get diagnostics n_apps = row_count;
  update tasks t set assigned_to = null
   where t.assigned_to is not null and t.status in ('open', 'in_progress', 'waiting') and app.staff_is_test(t.assigned_to) and app.task_is_real(t);
  get diagnostics n_tasks = row_count;
  return jsonb_build_object('leads', n_leads, 'lead_credit', n_src, 'owners', n_owners, 'applications', n_apps, 'tasks', n_tasks, 'requests', n_req);
end $$;

-- ================================================================ 4. the leads nobody followed up
create or replace function app.owner_leads_follow_up_now() returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  l record;
  n integer := 0;
begin
  for l in select * from leads x
            where x.kind in ('owner_program', 'owner_recruit') and x.followup_stop_reason = 'On file before the automatic follow-ups'
              and coalesce(x.pipeline_stage, 'new') = 'new' and x.replied_at is null and x.do_not_contact_at is null and x.owner_id is null
              and x.status in ('new', 'contacted', 'qualified') and not app.email_is_test(x.email) loop
    perform app.raise_task(p_type => 'owner_lead_follow_up', p_queue => 'admin',
      p_title => 'Follow up now: ' || coalesce(l.name, l.email, l.phone, 'an owner lead'),
      p_detail => format('%s asked about the owner program on %s, before the automatic follow-ups existed, and nobody followed up. Call or email them, then move the card in the Owner pipeline.%s',
                         coalesce(l.name, 'Someone'), to_char(app.local_date(l.created_at), 'FMMonth FMDD'),
                         coalesce(' Contact: ' || nullif(concat_ws(', ', l.email, l.phone), '') || '.', '')),
      p_related_table => 'leads', p_related_id => l.id, p_priority => 'high', p_dedupe => 'owner_lead_follow_up:' || l.id);
    update leads set followup_stop_reason = 'On file before the automatic follow-ups: an Admin follows up (To do)', updated_at = now() where id = l.id;
    n := n + 1;
  end loop;
  return n;
end $$;

select app.clear_test_account_credit();
select app.owner_leads_follow_up_now();

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('email_is_test', 'lead_real_assignee', 'leads_no_test_staff', 'owners_no_test_staff', 'owner_applications_no_test_staff',
                                                     'task_is_real', 'tasks_no_test_staff', 'owner_sales_credit', 'owner_sales_credit_pre0343', 'clear_test_account_credit',
                                                     'owner_leads_follow_up_now') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
