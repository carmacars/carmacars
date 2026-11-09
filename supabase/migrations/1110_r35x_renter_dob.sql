-- 1110_r35x_renter_dob.sql
-- Release 35, UX batch (docs/changes/2026-11-09-r35-ux-batch.md). SCHEMA_MARKER 1110.
-- The owner, November 9: "renters have the ability to extend rentals and to adjust all of the details on their profile
-- right? like dob and email and phone number and name".
-- Email and phone stay self-serve with their verification (ChangeEmail, SignInSettings, 0812). The name and the date of
-- birth: a renter sets or edits them in the profile while no licence of theirs is verified (the renter record, the account
-- and the account holder's driver change at once). Once a licence is verified (the date of birth drives the young driver
-- fees and the insurer's eligibility), a change is a correction request (0812's name_change_requests, now with the date of
-- birth), shown in the profile as waiting, which Sales, customer service or an Admin approve or decline against the licence
-- (the task goes to customer service's queue). Owners and investors keep 0812's Admin-only name change.
-- No applied migration is edited: app.self_profile_view, app.name_change_decide, app.name_change_pending and app.door are
-- wrapped (_pre1110).
set local check_function_bodies = off;

create or replace function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

alter table name_change_requests
  add column if not exists current_dob date,
  add column if not exists requested_dob date;
comment on column name_change_requests.requested_dob is 'A renter''s date of birth correction (1110), checked against the licence: approving changes the renter and the account holder''s driver. Null: the name only.';

-- a licence of the renter is verified: the name and the date of birth are checked against it from then on
create or replace function app.renter_identity_locked(p_renter uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from renters r where r.id = p_renter and r.identity_status = 'verified')
      or exists (select 1 from drivers d where d.renter_id = p_renter and d.is_account_holder and d.identity_status = 'verified')
$$;

-- p: legal_name, date_of_birth (YYYY-MM-DD), reason. Saved at once while no licence is verified; a correction request after.
create or replace function app.profile_identity_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r renters;
  v_name text := nullif(btrim(coalesce(p ->> 'legal_name', '')), '');
  v_dob date;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_age integer;
  n name_change_requests;
begin
  select * into r from renters where user_id = p_by limit 1;
  if r.id is null then raise exception 'Your details are saved with your first booking request' using errcode = 'P0002'; end if;
  begin
    v_dob := nullif(p ->> 'date_of_birth', '')::date;
  exception when others then raise exception 'Enter the date of birth as on your licence' using errcode = '22023';
  end;
  if v_name is not null and length(v_name) < 3 then raise exception 'Write your full legal name, as on your licence' using errcode = '22023'; end if;
  if v_dob is not null then
    v_age := extract(year from age(app.today(), v_dob));
    if v_dob > app.today() or v_age > 110 then raise exception 'Check the date of birth' using errcode = '22023'; end if;
    if v_age < 16 then raise exception 'A driver is 16 or older' using errcode = '22023'; end if;
  end if;
  v_name := coalesce(v_name, r.legal_name);
  if v_name is not distinct from r.legal_name and (v_dob is null or v_dob is not distinct from r.date_of_birth) then
    raise exception 'Nothing changed' using errcode = '22023';
  end if;
  if not app.renter_identity_locked(r.id) then
    update renters set legal_name = v_name, date_of_birth = coalesce(v_dob, date_of_birth) where id = r.id;
    update users set full_name = v_name where id = p_by;
    update drivers set full_name = v_name, date_of_birth = coalesce(v_dob, date_of_birth) where renter_id = r.id and is_account_holder;
    return jsonb_build_object('ok', true, 'saved', true, 'legal_name', v_name, 'date_of_birth', coalesce(v_dob, r.date_of_birth));
  end if;
  if v_reason is null or length(v_reason) < 5 then raise exception 'Say why it changes (a typo, a legal name change): it is checked against your licence' using errcode = '22023'; end if;
  update name_change_requests set status = 'cancelled', decided_at = now(), decision_note = 'Replaced by a new request' where user_id = p_by and status = 'requested';
  insert into name_change_requests (user_id, current_name, requested_name, reason, current_dob, requested_dob)
  values (p_by, r.legal_name, v_name, left(v_reason, 500), r.date_of_birth, case when v_dob is distinct from r.date_of_birth then v_dob end) returning * into n;
  perform app.raise_task(p_type => 'name_change_approve', p_queue => 'cs',
    p_title => left(format('Check against the licence: %s%s', case when v_name <> r.legal_name then format('name %s to %s', r.legal_name, v_name) else r.legal_name end,
                           case when n.requested_dob is not null then format(', date of birth %s to %s', coalesce(r.date_of_birth::text, 'none'), n.requested_dob) else '' end), 200),
    p_detail => left(format('A verified renter asked to correct their details: %s. Approve only if the licence shows them.', v_reason), 2000),
    p_renter => r.id, p_related_table => 'name_change_requests', p_related_id => n.id, p_dedupe => 'name_change_approve:' || n.id, p_created_by => p_by);
  return jsonb_build_object('ok', true, 'pending', true, 'id', n.id);
end $$;
comment on function app.profile_identity_save(uuid, jsonb) is 'A renter''s name and date of birth (1110): saved at once while no licence is verified, a correction request for Sales, customer service or an Admin after.';

-- the profile: the date of birth, whether it is checked against a licence now, and a waiting correction with its date
alter function app.self_profile_view(uuid, jsonb) rename to self_profile_view_pre1110;
create function app.self_profile_view(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.self_profile_view_pre1110(p_by, p);
  r renters;
begin
  select * into r from renters where user_id = (v ->> 'user_id')::uuid limit 1;
  if r.id is null then return v; end if;
  return v || jsonb_build_object('renter', true, 'date_of_birth', r.date_of_birth, 'identity_locked', app.renter_identity_locked(r.id),
    'pending', (select jsonb_build_object('id', n.id, 'requested_name', n.requested_name, 'requested_dob', n.requested_dob, 'reason', n.reason, 'requested_at', n.requested_at)
                  from name_change_requests n where n.user_id = r.user_id and n.status = 'requested'));
end $$;
select pg_temp.copy_grants('app.self_profile_view(uuid, jsonb)'::regprocedure, 'app.self_profile_view_pre1110(uuid, jsonb)'::regprocedure);

-- Sales, customer service or an Admin decide a renter's correction; an Admin alone decides an owner's or investor's
alter function app.name_change_decide(uuid, jsonb) rename to name_change_decide_pre1110;
create function app.name_change_decide(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  n name_change_requests;
  v text := coalesce(p ->> 'decision', 'approve');
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  v_renter uuid;
  v_out jsonb;
begin
  select * into n from name_change_requests where id::text = p ->> 'id';
  if n.id is null then raise exception 'Request not found' using errcode = 'P0002'; end if;
  select r.id into v_renter from renters r where r.user_id = n.user_id limit 1;
  if v in ('approve', 'decline') and not app.user_is_admin(p_by) then
    if v_renter is null or not app.user_va_has(p_by, 'cs', 'sales') then
      raise exception 'Sales, customer service or an Admin decide a renter''s correction; an Admin decides other name changes' using errcode = '42501';
    end if;
    if n.status <> 'requested' then raise exception 'This request was already %', n.status using errcode = '23514'; end if;
    update name_change_requests set status = case v when 'approve' then 'approved' else 'declined' end, decided_by = p_by, decided_at = now(), decision_note = v_note where id = n.id;
    if v = 'approve' then
      update users set full_name = n.requested_name where id = n.user_id;
      update renters set legal_name = n.requested_name where user_id = n.user_id;
    end if;
    update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = initcap(v) || 'd' || coalesce(': ' || v_note, '')
     where task_type = 'name_change_approve' and related_table = 'name_change_requests' and related_id = n.id and status in ('open', 'in_progress', 'waiting');
    v_out := jsonb_build_object('ok', true, 'status', case v when 'approve' then 'approved' else 'declined' end, 'user_id', n.user_id);
  else
    v_out := app.name_change_decide_pre1110(p_by, p);
  end if;
  if v = 'approve' and v_renter is not null then
    update drivers set full_name = n.requested_name, date_of_birth = coalesce(n.requested_dob, date_of_birth) where renter_id = v_renter and is_account_holder;
    if n.requested_dob is not null then update renters set date_of_birth = n.requested_dob where id = v_renter; end if;
  end if;
  return v_out;
end $$;
select pg_temp.copy_grants('app.name_change_decide(uuid, jsonb)'::regprocedure, 'app.name_change_decide_pre1110(uuid, jsonb)'::regprocedure);

-- the waiting corrections of one renter for Sales and customer service too (with the date of birth)
alter function app.name_change_pending(uuid, jsonb) rename to name_change_pending_pre1110;
create function app.name_change_pending(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_user uuid := (select r.user_id from renters r where r.id::text = coalesce(p ->> 'renter_id', ''));
begin
  if not app.user_is_admin(p_by) then
    if not (app.user_va_has(p_by, 'cs', 'sales') and p ? 'renter_id') then raise exception 'Admin only' using errcode = '42501'; end if;
  end if;
  if p ? 'renter_id' then
    if v_user is null then return '[]'::jsonb; end if;
    return coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'user_id', n.user_id, 'current_name', n.current_name, 'requested_name', n.requested_name,
                                                         'current_dob', n.current_dob, 'requested_dob', n.requested_dob, 'reason', n.reason, 'requested_at', n.requested_at) order by n.requested_at)
                       from name_change_requests n where n.status = 'requested' and n.user_id = v_user), '[]'::jsonb);
  end if;
  return app.name_change_pending_pre1110(p_by, p);
end $$;
select pg_temp.copy_grants('app.name_change_pending(uuid, jsonb)'::regprocedure, 'app.name_change_pending_pre1110(uuid, jsonb)'::regprocedure);

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1110;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'ops_do' and p_name = 'profile_identity_save' then
    perform app.door_begin(p_user, p_aal);
    return app.profile_identity_save(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre1110(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre1110(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['renter_identity_locked', 'profile_identity_save', 'self_profile_view_pre1110', 'name_change_decide_pre1110',
                    'name_change_pending_pre1110', 'door_pre1110'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
