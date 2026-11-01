-- 0342: Sales see only their own owner leads (Release 26, docs/changes/2026-11-06-sales-owner-recruitment.md). The owner,
-- viewing a salesperson's portal: "Darren sees an owner pipeline with shit I've never seen before". The owner pipeline of
-- 0217 and the Owner leads screen of 0031 showed every prospective owner (classified-ad leads, website enquiries, other
-- people's) with their contact details to anyone working as Sales.
--   1. The owner pipeline (va_read owner_pipeline, va_do owner_pipeline_*) is for Admins and customer service only
--      (app.owner_pipeline_allowed). A person who also works as customer service keeps it.
--   2. Someone who is Sales but not customer service sees, of the owner leads (kinds owner_program and owner_recruit), only
--      the ones they invited (leads.sourced_by), added (payload.added_by) or were given (assigned_to: a website lead goes to
--      the least busy Sales person with its task, 0022), on My sales, Owners you bring in: va_read
--      owner_leads lists only those and only the applications of owners they brought in; va_list leads leaves the others
--      out; va_do lead_update refuses the others.
--   3. Row security on leads: the Sales policies read and update only the leads that are not owner leads, or their own.
-- SCHEMA_MARKER 0342. No applied migration is edited.
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

-- ================================================================ the rules
-- Every owner lead: an Admin, or customer service (their work needs the whole pipeline).
create or replace function app.owner_leads_full(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_is_admin(p_user) or app.user_va_has(p_user, 'cs')
$$;

-- An owner lead a salesperson may see: one they invited or added, or one given to them (a website lead's least busy
-- Sales person, 0022, whose task they work). Any other lead (a renter enquiry, a buyer) is not an owner lead.
create or replace function app.lead_visible_to_sales(p_kind text, p_sourced_by uuid, p_assigned_to uuid, p_payload jsonb, p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce(p_kind not in ('owner_program', 'owner_recruit') or p_sourced_by = p_user or p_assigned_to = p_user or (p_payload ->> 'added_by') = p_user::text, false)
$$;

create or replace function app.owner_pipeline_allowed(p_by uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.owner_leads_full(p_by)
$$;

-- Owner leads for a salesperson who is not customer service: their own leads, the applications of owners they brought in.
create or replace function app.sales_owner_leads(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'leads', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'email', l.email, 'phone', l.phone, 'message', l.message, 'status', l.status,
                          'created_at', l.created_at, 'assigned_to', l.assigned_to, 'assignee_name', (select u.full_name from users u where u.id = l.assigned_to),
                          'vehicle', l.payload ->> 'vehicle') order by l.created_at desc)
                       from leads l where l.kind = 'owner_program' and l.status in ('new', 'contacted', 'qualified')
                        and (l.sourced_by = p_user or l.assigned_to = p_user or (l.payload ->> 'added_by') = p_user::text)), '[]'::jsonb),
    'applications', coalesce((select jsonb_agg(jsonb_build_object('application_number', a.application_number, 'owner_name', o.legal_name, 'vehicle_count', a.vehicle_count,
                                 'created_at', a.created_at, 'source', a.source,
                                 'statuses', (select jsonb_agg(distinct vo.status) from vehicles v join vehicle_onboardings vo on vo.vehicle_id = v.id where v.owner_id = o.id)) order by a.created_at desc)
                             from owner_applications a join owners o on o.id = a.owner_id
                            where a.created_at > now() - interval '90 days' and (o.recruited_by = p_user or a.sourced_by = p_user)), '[]'::jsonb))
$$;

-- The kinds of lead a salesperson lists: every kind but the owner leads (theirs are on My sales).
create or replace function app.lead_kinds_for_sales() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(m[1] order by m[1]), '[]'::jsonb)
    from regexp_matches(coalesce((select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'leads'::regclass and conname = 'leads_kind_check'), ''), '''([a-z_]+)''', 'g') m
   where m[1] not in ('owner_program', 'owner_recruit')
$$;

-- ================================================================ row security
drop policy if exists sales_read on leads;
create policy sales_read on leads for select to authenticated
  using (app.va_has('sales') and app.lead_visible_to_sales(kind, sourced_by, assigned_to, payload, app.uid()));
drop policy if exists sales_update on leads;
create policy sales_update on leads for update to authenticated
  using (app.va_has('sales') and app.lead_visible_to_sales(kind, sourced_by, assigned_to, payload, app.uid()))
  with check (app.va_has('sales') and app.lead_visible_to_sales(kind, sourced_by, assigned_to, payload, app.uid()));

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0342;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  v_kinds jsonb;
  l leads;
begin
  if p_call in ('va_read', 'va_list', 'va_do') and p_user is not null and not app.owner_leads_full(p_user) then
    if p_call = 'va_read' and p_name = 'owner_leads' then
      perform app.door_begin(p_user, p_aal);
      if not app.user_va_has(p_user, 'sales') then raise exception 'Not permitted' using errcode = '42501'; end if;
      return app.sales_owner_leads(p_user);
    end if;
    if p_call = 'va_list' and p_name = 'leads' then
      -- the kinds asked for, less the owner leads; none asked for: every other kind
      select coalesce(jsonb_agg(k), '[]'::jsonb) into v_kinds
        from jsonb_array_elements(case when jsonb_typeof(p_ #> '{eq,kind}') = 'array' then p_ #> '{eq,kind}'
                                       when p_ #> '{eq,kind}' is not null then jsonb_build_array(p_ #> '{eq,kind}') else app.lead_kinds_for_sales() end) k
       where k #>> '{}' not in ('owner_program', 'owner_recruit');
      if jsonb_array_length(v_kinds) = 0 then v_kinds := '["none"]'::jsonb; end if;
      p_ := jsonb_set(p_, '{eq}', coalesce(p_ -> 'eq', '{}'::jsonb) || jsonb_build_object('kind', v_kinds));
      return app.door_pre0342(p_user, p_aal, p_call, p_name, p_);
    end if;
    if p_call = 'va_do' and p_name = 'lead_update' then
      select * into l from leads where id = nullif(p_ ->> 'id', '')::uuid;
      if l.id is not null and not app.lead_visible_to_sales(l.kind, l.sourced_by, l.assigned_to, l.payload, p_user) then
        raise exception 'Lead not found' using errcode = 'P0002';
      end if;
    end if;
  end if;
  return app.door_pre0342(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0342(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('owner_leads_full', 'sales_owner_leads', 'lead_kinds_for_sales', 'door_pre0342') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
-- the row security predicate runs as the browser session: it must stay callable there
revoke all on function app.lead_visible_to_sales(text, uuid, uuid, jsonb, uuid) from public, anon;
grant execute on function app.lead_visible_to_sales(text, uuid, uuid, jsonb, uuid) to authenticated, service_role;
