-- 0823: one onboarding checklist for the owner, staff and Admin (Release 34, part P;
-- docs/changes/2026-11-08-r34-owner-onboarding.md). No applied migration is edited.
--
-- app.onboarding_overview: everything the shared "Onboarding checklist" shows for an owner, per car still onboarding:
-- the checklist rows of app.onboarding_checklist (0022, the source of truth for what is done), with the facts the
-- steps need to say who they wait on and why one is blocked: the terms (approved or waiting for an Admin), the
-- onboarding photos and their review (0821), the government forms (0822: due, made, drafts and what they miss), the
-- upfront invoice and the Vehicle Schedule. The wording, the waiting-on and the one next action per step are made in
-- the website (src/features/onboarding/steps.ts), for the viewer: the owner, staff or an Admin.
-- Who reads it: the owner (their own), an Admin, customer service and fleet (any owner), sales (the owners they brought in).
set local check_function_bodies = off;

create function app.onboarding_overview(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  o owners;
  v_viewer text;
begin
  select * into o from owners where id = nullif(p ->> 'owner_id', '')::uuid;
  if o.id is null then raise exception 'Owner not found' using errcode = 'P0002'; end if;
  v_viewer := case when app.user_is_admin(p_by) then 'admin'
                   when app.user_va_has(p_by, 'cs', 'fleet') or (app.user_va_has(p_by, 'sales') and o.recruited_by = p_by) then 'staff'
                   when app.user_is_owner_of(p_by, o.id) then 'owner' end;
  if v_viewer is null then raise exception 'Not permitted' using errcode = '42501'; end if;
  return jsonb_build_object('viewer', v_viewer,
    'owner', jsonb_build_object('id', o.id, 'name', o.legal_name, 'type', o.owner_type, 'fleet_supplier', coalesce(o.onboarding_route = 'fleet_supplier', false),
      'missing', to_jsonb(coalesce(app.owner_missing_fields(o.id), '{}')), 'has_account', o.user_id is not null, 'email', o.email, 'phone', o.phone),
    'trackers', coalesce((app.settings()).trackers_available, false),
    'cars', (select coalesce(jsonb_agg(c order by c ->> 'created_at', c ->> 'vehicle_id'), '[]'::jsonb) from (
      select jsonb_build_object('vehicle_id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate, 'status', v.status, 'created_at', v.created_at,
        'onboarding_status', ob.status, 'mode', coalesce(s.management_mode::text, ob.proposed_management_mode::text, v.management_mode::text),
        'application_id', ob.application_id, 'application_number', (select a.application_number from owner_applications a where a.id = ob.application_id),
        'terms_pending', ob.pending_terms is not null,
        'schedule', case when s.id is not null then jsonb_build_object('number', s.schedule_number, 'signed', s.signed_at is not null) end,
        'checklist', (select coalesce(jsonb_agg(jsonb_build_object('code', c.code, 'label', c.label, 'status', c.status, 'waits_on', c.waits_on,
                        'owner_action', c.owner_action, 'staff_action', c.staff_action) order by c.sort_order), '[]'::jsonb) from app.onboarding_checklist(v.id) c),
        'photos', (select jsonb_build_object('permit', count(*) filter (where d.kind = 'ownership_permit'),
                     'waiting', count(*) filter (where d.review_status = 'waiting'), 'rejected', count(*) filter (where d.review_status = 'rejected'),
                     'approved', count(*) filter (where d.review_status = 'approved'), 'total', count(*),
                     'note', (select x.review_note from documents x where x.vehicle_id = v.id and x.review_status = 'rejected' and x.removed_at is null and x.purged_at is null
                                and app.onboarding_photo_kind(x.kind::text) order by x.reviewed_at desc limit 1))
                     from documents d where d.vehicle_id = v.id and app.onboarding_photo_kind(d.kind::text) and d.removed_at is null and d.purged_at is null),
        'forms', jsonb_build_object('due', app.registry_forms_due(v.id),
                   'needed', coalesce(cardinality(case when app.registry_forms_due(v.id) then ob.government_forms end), 0),
                   'made', (select count(*) from government_form_fills g where g.vehicle_id = v.id and g.superseded_at is null and g.form_code = any (coalesce(ob.government_forms, '{}'))),
                   'drafts', (select count(*) from government_form_fills g where g.vehicle_id = v.id and g.superseded_at is null and g.status = 'draft' and g.form_code = any (coalesce(ob.government_forms, '{}'))),
                   'signed', (select count(*) from government_form_fills g where g.vehicle_id = v.id and g.superseded_at is null and g.status in ('signed', 'filed') and g.form_code = any (coalesce(ob.government_forms, '{}'))),
                   'missing', (select coalesce(jsonb_agg(distinct m), '[]'::jsonb) from government_form_fills g cross join unnest(g.missing) m
                                where g.vehicle_id = v.id and g.superseded_at is null and g.status = 'draft' and m not like 'PDF field %')),
        'upfront', (select jsonb_build_object('number', i.invoice_number, 'status', i.status) from owner_invoices i where i.id = ob.upfront_invoice_id)) c
        from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id
        left join vehicle_schedules s on s.vehicle_id = v.id and s.superseded_by is null
       where v.owner_id = o.id and v.status not in ('declined', 'exited', 'total_loss') and ob.status not in ('declined', 'withdrawn', 'enrolled')
         and (nullif(p ->> 'vehicle_id', '') is null or v.id = (p ->> 'vehicle_id')::uuid)) x(c)));
end $$;

-- the staff portals' Owners list (customer service, fleet; an Admin): the owners with a car onboarding first, a search
-- by name, email or plate over every owner in the program
create function app.onboarding_owners(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_q text := lower(nullif(btrim(coalesce(p ->> 'q', '')), ''));
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet')) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(x order by (x ->> 'onboarding')::integer desc, x ->> 'name'), '[]'::jsonb) from (
    select jsonb_build_object('id', o.id, 'name', o.legal_name, 'email', o.email,
      'cars', (select count(*) from vehicles v where v.owner_id = o.id and v.status not in ('declined', 'exited', 'total_loss')),
      'onboarding', (select count(*) from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id where v.owner_id = o.id
                       and v.status not in ('declined', 'exited', 'total_loss') and ob.status not in ('declined', 'withdrawn', 'enrolled'))) x
      from owners o
     where coalesce(o.kind, 'program') = 'program'
       and (v_q is null or lower(o.legal_name) like '%' || v_q || '%' or lower(coalesce(o.email, '')) like '%' || v_q || '%'
            or exists (select 1 from vehicles v where v.owner_id = o.id and (lower(coalesce(v.plate, '')) like '%' || v_q || '%' or lower(v.vin) like '%' || v_q || '%')))
       and (v_q is not null or exists (select 1 from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id where v.owner_id = o.id
                                        and v.status not in ('declined', 'exited', 'total_loss') and ob.status not in ('declined', 'withdrawn', 'enrolled')))
     limit 200) y(x));
end $$;

revoke all on function app.onboarding_overview(uuid, jsonb) from public, anon, authenticated;
revoke all on function app.onboarding_owners(uuid, jsonb) from public, anon, authenticated;
