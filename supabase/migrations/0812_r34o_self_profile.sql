-- 0812_r34o_self_profile.sql
-- Release 34 part O (docs/changes/2026-11-08-r34-book-now-connector.md, section A): a profile for everyone, in every portal.
-- A person changes their display name at once. The legal name (the name on signed agreements and registry forms) is not
-- edited freely: "Request a name change" makes a request and an Admin task, and an Admin approves or declines in one tap
-- (the To do, or the person's page); approving changes users.full_name and the legal name of the person's renter, owner or
-- investor record. Email, password and phone use the existing flows (ChangeEmail, SignInSettings, the password reset).
set local check_function_bodies = off;

alter table users add column if not exists display_name text check (display_name is null or length(btrim(display_name)) between 1 and 80);
comment on column users.display_name is 'The name a person chose to be greeted with in their portal (0812). The legal name stays users.full_name and the legal_name of the renter, owner or investor record; it changes only through name_change_requests.';

create table name_change_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users (id) on delete cascade,
  current_name text not null,
  requested_name text not null check (length(btrim(requested_name)) >= 3),
  reason text,
  status text not null default 'requested' check (status in ('requested', 'approved', 'declined', 'cancelled')),
  requested_at timestamptz not null default now(),
  decided_by uuid references users (id),
  decided_at timestamptz,
  decision_note text
);
comment on table name_change_requests is 'A person''s request to change the legal name on their agreements (0812). An Admin approves (the name changes on the account and the renter, owner or investor record) or declines.';
create unique index name_change_requests_one_open on name_change_requests (user_id) where status = 'requested';
alter table name_change_requests enable row level security;
create policy admin_all on name_change_requests for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on name_change_requests from anon;
grant select, insert, update on name_change_requests to authenticated;
grant all on name_change_requests to service_role;
create trigger audit_name_change_requests after insert or update or delete on name_change_requests for each row execute function app.audit_row();

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('name_change_approve', 'admin', 'Approve a name change', 'normal', 'none', null, null, null,
   'Someone asked to change the legal name on their agreements. Approve: the name changes on their account and record. Decline: nothing changes.')
on conflict (task_type) do nothing;

-- the legal name as the person's own record has it
create function app.self_legal_name(p_user uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce((select o.legal_name from owners o where o.user_id = p_user limit 1), (select i.legal_name from investors i where i.user_id = p_user limit 1),
                  (select r.legal_name from renters r where r.user_id = p_user limit 1), (select u.full_name from users u where u.id = p_user))
$$;

-- p {user_id?}: the signed-in person's own profile; an Admin may name another person
create function app.self_profile_view(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_user uuid := coalesce(nullif(p ->> 'user_id', '')::uuid, p_by);
  u users;
begin
  if v_user <> p_by and not app.user_is_admin(p_by) then raise exception 'Only an Admin opens another person''s profile' using errcode = '42501'; end if;
  select * into u from users where id = v_user;
  if u.id is null then raise exception 'Person not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('user_id', u.id, 'email', u.email, 'display_name', u.display_name, 'account_name', u.full_name, 'legal_name', app.self_legal_name(u.id),
    'pending', (select jsonb_build_object('id', n.id, 'requested_name', n.requested_name, 'reason', n.reason, 'requested_at', n.requested_at)
                  from name_change_requests n where n.user_id = u.id and n.status = 'requested'));
end $$;

create function app.self_display_name_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v text := nullif(btrim(coalesce(p ->> 'display_name', '')), '');
begin
  if v is not null and length(v) > 80 then raise exception 'Keep the name to 80 characters' using errcode = '22023'; end if;
  update users set display_name = v where id = p_by;
  return jsonb_build_object('ok', true, 'display_name', v);
end $$;

create function app.name_change_request(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_new text := nullif(btrim(coalesce(p ->> 'requested_name', '')), '');
  v_cur text := app.self_legal_name(p_by);
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  n name_change_requests;
begin
  if v_new is null or length(v_new) < 3 then raise exception 'Write the full name as it should appear on your agreements' using errcode = '22023'; end if;
  if lower(v_new) = lower(v_cur) then raise exception 'That is already your name on file' using errcode = '22023'; end if;
  if v_reason is null or length(v_reason) < 5 then raise exception 'Say why the name changes (a marriage, a legal change, a typo)' using errcode = '22023'; end if;
  update name_change_requests set status = 'cancelled', decided_at = now(), decision_note = 'Replaced by a new request' where user_id = p_by and status = 'requested';
  insert into name_change_requests (user_id, current_name, requested_name, reason) values (p_by, v_cur, v_new, left(v_reason, 500)) returning * into n;
  perform app.raise_task(p_type => 'name_change_approve', p_queue => 'admin',
    p_title => left(format('Name change: %s to %s', v_cur, v_new), 200),
    p_detail => left(format('%s asked to change the legal name on their agreements: %s', v_cur, v_reason), 2000),
    p_related_table => 'name_change_requests', p_related_id => n.id, p_dedupe => 'name_change_approve:' || n.id, p_created_by => p_by);
  return jsonb_build_object('ok', true, 'id', n.id, 'status', n.status);
end $$;

-- an Admin approves or declines; the person cancels their own
create function app.name_change_decide(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  n name_change_requests;
  v text := coalesce(p ->> 'decision', 'approve');
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
begin
  select * into n from name_change_requests where id::text = p ->> 'id' for update;
  if n.id is null then raise exception 'Request not found' using errcode = 'P0002'; end if;
  if n.status <> 'requested' then raise exception 'This request was already %', n.status using errcode = '23514'; end if;
  if v = 'cancel' then
    if n.user_id <> p_by and not app.user_is_admin(p_by) then raise exception 'Only who asked, or an Admin, cancels it' using errcode = '42501'; end if;
  elsif not app.user_is_admin(p_by) then raise exception 'An Admin approves or declines a name change' using errcode = '42501';
  elsif v not in ('approve', 'decline') then raise exception 'Approve or decline' using errcode = '22023'; end if;
  update name_change_requests set status = case v when 'approve' then 'approved' when 'decline' then 'declined' else 'cancelled' end,
         decided_by = p_by, decided_at = now(), decision_note = v_note where id = n.id;
  if v = 'approve' then
    update users set full_name = n.requested_name where id = n.user_id;
    update renters set legal_name = n.requested_name where user_id = n.user_id;
    update owners set legal_name = n.requested_name where user_id = n.user_id and owner_type = 'individual';
    update investors set legal_name = n.requested_name where user_id = n.user_id and investor_type = 'individual';
  end if;
  update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = initcap(v) || 'd' || coalesce(': ' || v_note, '')
   where task_type = 'name_change_approve' and related_table = 'name_change_requests' and related_id = n.id and status in ('open', 'in_progress', 'waiting');
  return jsonb_build_object('ok', true, 'status', case v when 'approve' then 'approved' when 'decline' then 'declined' else 'cancelled' end, 'user_id', n.user_id);
end $$;

create function app.name_change_pending(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_user text := coalesce(nullif(p ->> 'user_id', ''),
    (select o.user_id::text from owners o where o.id::text = p ->> 'owner_id'), (select i.user_id::text from investors i where i.id::text = p ->> 'investor_id'),
    (select r.user_id::text from renters r where r.id::text = p ->> 'renter_id'));
begin
  if not app.user_is_admin(p_by) then raise exception 'Admin only' using errcode = '42501'; end if;
  if v_user is null and (p ? 'owner_id' or p ? 'investor_id' or p ? 'renter_id') then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'user_id', n.user_id, 'current_name', n.current_name, 'requested_name', n.requested_name, 'reason', n.reason, 'requested_at', n.requested_at) order by n.requested_at)
                     from name_change_requests n where n.status = 'requested' and (v_user is null or n.user_id::text = v_user)), '[]'::jsonb);
end $$;

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0812;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_name in ('self_profile', 'display_name_save', 'name_change_request', 'name_change_decide', 'name_change_pending') and p_call in ('ops_read', 'ops_do') then
    perform app.door_begin(p_user, p_aal);
    p := coalesce(p, '{}'::jsonb);
    return case p_name
      when 'self_profile' then app.self_profile_view(p_user, p)
      when 'display_name_save' then app.self_display_name_save(p_user, p)
      when 'name_change_request' then app.name_change_request(p_user, p)
      when 'name_change_decide' then app.name_change_decide(p_user, p)
      else app.name_change_pending(p_user, p) end;
  end if;
  return app.door_pre0812(p_user, p_aal, p_call, p_name, p);
end $$;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0812(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['self_legal_name', 'self_profile_view', 'self_display_name_save', 'name_change_request', 'name_change_decide', 'name_change_pending', 'door_pre0812'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
