-- 0088_owner_account_only.sql
-- The owner's request of October 21, 2026 (docs/changes/2026-10-21-owner-account-only.md): a car owner can open an
-- owner account without a car. The owner details and the password alone create the sign-in, the owner record and an
-- application "Account only: no car yet" (no per-car intake tasks); one light To do task asks staff to follow up. The
-- owner lands in the owner portal with "Add your first car" (the same application, VIN-first). The first car the owner
-- adds closes the follow-up and is an ordinary application.

alter table owner_applications drop constraint if exists owner_applications_status_check;
alter table owner_applications add constraint owner_applications_status_check
  check (status = any (array['new', 'waiting_on_owner', 'approved', 'declined', 'account_only']));
comment on column owner_applications.status is 'new, waiting_on_owner, approved, declined, or account_only (0088: the owner opened an account with no car yet).';

-- The application in one call (0022), now also with no car: p.account_only true and no vehicles. Everything else
-- (the owner, a second press of Submit, someone applying for themselves only, the lead, the draft) is 0022's.
alter function app.submit_owner_application(jsonb, uuid) rename to submit_owner_application_pre0088;
create or replace function app.submit_owner_application(p jsonb, p_by uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_owner uuid := nullif(p ->> 'owner_id', '')::uuid;
  v_app uuid := gen_random_uuid();
  v_number text;
  v_staff boolean := p_by is not null and (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet'));
  v_draft uuid := nullif(p ->> 'draft_id', '')::uuid;
  v_out jsonb;
  v_result jsonb;
  o owners;
begin
  if p is not null and coalesce(jsonb_array_length(case when jsonb_typeof(p -> 'vehicles') = 'array' then p -> 'vehicles' end), 0) > 0 then
    v_out := app.submit_owner_application_pre0088(p, p_by);
    -- the owner's first car: the follow-up of an account opened without one is done
    update tasks set status = 'done', completed_at = now(), completion_note = coalesce(completion_note, 'The owner added a car')
     where task_type = 'owner_signup_no_car' and owner_id = (v_out ->> 'owner_id')::uuid and status in ('open', 'in_progress', 'waiting');
    return v_out;
  end if;
  if p is null or not coalesce((p ->> 'account_only')::boolean, false) then
    raise exception 'An application needs at least one vehicle' using errcode = '22023';
  end if;
  if v_draft is not null and exists (select 1 from form_drafts f where f.id = v_draft and f.submitted_at is not null) then
    return (select f.result from form_drafts f where f.id = v_draft);   -- a second press of "Submit"
  end if;
  if p_by is not null and not v_staff then
    if v_owner is null then
      select x.id into v_owner from owners x where x.user_id = p_by order by x.created_at limit 1;
    elsif not exists (select 1 from owners x where x.id = v_owner and x.user_id = p_by) then
      raise exception 'Not permitted: an owner opens only their own account' using errcode = '42501';
    end if;
    p := jsonb_set(p, '{owner}', coalesce(p -> 'owner', '{}'::jsonb) || jsonb_build_object('user_id', p_by));
  end if;
  v_owner := app.save_application_owner(v_owner, p -> 'owner', p_by);
  select * into o from owners where id = v_owner;

  -- one account-only application per owner while they have no car
  select a.id, a.application_number into v_app, v_number from owner_applications a where a.owner_id = v_owner and a.status = 'account_only' limit 1;
  if v_number is null then
    v_app := gen_random_uuid();
    insert into owner_applications (id, owner_id, lead_id, form_draft_id, source, submitted_by, note, status, vehicle_count)
    values (v_app, v_owner, nullif(p ->> 'lead_id', '')::uuid, v_draft,
            coalesce(nullif(p ->> 'source', ''), case when v_staff then 'staff' else 'web' end), p_by, nullif(p ->> 'note', ''), 'account_only', 0)
    returning application_number into v_number;
  end if;
  if not exists (select 1 from vehicles v where v.owner_id = v_owner) then
    perform app.raise_task(p_type => 'owner_signup_no_car', p_queue => 'admin',
        p_title => format('New owner signed up without a car: follow up with %s', o.legal_name),
        p_detail => format('%s opened an owner account with no car yet (application %s). Call or email to help them add their first car.', o.legal_name, v_number),
        p_owner => v_owner, p_related_table => 'owner_applications', p_related_id => v_app, p_priority => 'normal', p_created_by => p_by,
        p_dedupe => 'owner_signup_no_car:' || v_owner);
  end if;
  if nullif(p ->> 'lead_id', '') is not null then
    update leads set status = 'converted', owner_id = v_owner where id = (p ->> 'lead_id')::uuid;
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'owner_account_only', 'owner_applications', v_app::text, jsonb_build_object('owner_id', v_owner, 'application_number', v_number));
  v_result := jsonb_build_object('application_id', v_app, 'application_number', v_number, 'owner_id', v_owner, 'account_only', true,
                                 'owner_missing', to_jsonb(app.owner_missing_fields(v_owner)), 'vehicles', '[]'::jsonb);
  if v_draft is not null then perform app.submit_form_draft(v_draft, v_result); end if;
  return v_result;
end $$;

-- The applications inbox (0054) with the account-only ones: "Account only: no car yet" while the owner has no car.
create or replace function app.applications_list(p_admin uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_admin);
  return (select jsonb_build_object(
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'application_number', a.application_number, 'status', a.status, 'created_at', a.created_at,
              'owner', o.legal_name, 'email', o.email, 'owner_type', o.owner_type, 'is_test', o.is_test, 'source', a.source,
              'vehicles', (select coalesce(jsonb_agg(app.vehicle_name(v.id) order by v.created_at), '[]'::jsonb) from vehicles v where v.owner_id = o.id),
              'checks_done', (select count(*) from jsonb_each(a.checks) c where c.value ->> 'status' in ('ok', 'not_needed')),
              'requested_at', a.requested_at, 'owner_replied_at', a.owner_replied_at) order by a.created_at desc)
             from owner_applications a join owners o on o.id = a.owner_id
            where coalesce(nullif(p ->> 'status', ''), a.status) = a.status
              and (a.status <> 'account_only' or not exists (select 1 from vehicles v where v.owner_id = o.id))), '[]'::jsonb),
    'counts', (select jsonb_object_agg(s, (select count(*) from owner_applications x where x.status = s
                                                 and (s <> 'account_only' or not exists (select 1 from vehicles v where v.owner_id = x.owner_id))))
                 from unnest(array['new', 'waiting_on_owner', 'approved', 'declined', 'account_only']) s)));
end $$;

revoke all on function app.submit_owner_application(jsonb, uuid), app.submit_owner_application_pre0088(jsonb, uuid) from public, anon, authenticated;
do $$
declare
  g text;
begin
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.submit_owner_application_pre0088(jsonb, uuid)'::regprocedure, 'execute') then
      execute format('grant execute on function app.submit_owner_application(jsonb, uuid) to %I', g);
    end if;
  end loop;
end $$;
