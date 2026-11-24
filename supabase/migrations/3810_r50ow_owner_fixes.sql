-- 3810: owner fixes of Release 50 (owners), reported by an owner on November 24, 2026. docs/changes/2026-11-24-r50-sign-first.md.
-- No applied migration is edited: the functions it changes are wrapped (renamed with the suffix _pre3810).
--   1. A booking's money in the owner portal, stable between views: the rental charge agreed (before tax), what the
--      owner's approved statements carried for it so far (and for how many of its days), and its days. The card no longer
--      reads as the whole story when part of a long rental is still to come on a later statement.
--   2. Pickup not recorded, car presumed out: a confirmed booking whose pickup time passed with no handover recorded
--      (app.booking_pickup_unrecorded) keeps the car busy after its return time until someone records the handover, the
--      return or a no-show: the car is not available and no new offer goes on it (app.vehicle_is_available), the offer
--      screens show it as a conflict, the owner portal lists it as on a trip ("Pickup not recorded, car presumed out"), and
--      Fleet (then the Admins, once its return time passed) get the To do to record the handover, every 15 minutes until done.
--   3. The CarmaCars countersignature of Form D (Part 2) printed the owner's drawn signature: the PDF renderer put the
--      signer's image on the first row of every signature table (src/features/agreement/render.ts, fixed). The Form D
--      copies already filed with a drawn signature are filed again from the corrected renderer (their pdf job queued
--      again; the old copy is kept, marked replaced) and the owner is told (owner_document_reissued).
--   4. An Admin changes a car's Onboarding Method after its terms are set and before its Vehicle Schedule is signed
--      (app.set_onboarding_method, the owner page and the connector's set_onboarding_method, previewed then confirmed): the
--      plan, the schedule entry and the government forms follow; the agreements and Forms A and B are made again from the
--      records when the owner opens them. Data fix: Schedule VS-1012 (the Sonata N Line) is a Transfer, not Co-Registrant.
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

-- ================================================================ 1. a booking's money in the owner portal
-- Stored values only (nothing computed from the time of the view): the rental days, and the rental lines of the owner's
-- approved (or paid) statements for this booking.
create function app.owner_booking_money(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object(
    'rental_days', greatest(1, ceil(extract(epoch from b.return_at - b.pickup_at) / 86400.0))::integer,
    'on_statement_cents', coalesce((select sum(l.rental_charge_cents) from owner_statement_lines l join owner_statements s on s.id = l.owner_statement_id
                                     where l.booking_id = b.id and l.line_type = 'rental' and s.status in ('approved', 'paid')), 0),
    'on_statement_days', coalesce((select sum(coalesce(l.earned_days, 0)) from owner_statement_lines l join owner_statements s on s.id = l.owner_statement_id
                                     where l.booking_id = b.id and l.line_type = 'rental' and s.status in ('approved', 'paid')), 0),
    'on_statement_partial', coalesce((select bool_or(l.partial) from owner_statement_lines l join owner_statements s on s.id = l.owner_statement_id
                                       where l.booking_id = b.id and l.line_type = 'rental' and s.status in ('approved', 'paid')), false),
    'presumed_out', app.booking_pickup_unrecorded(b))
    from bookings b where b.id = p_booking
$$;

alter function app.owner_portal_bookings_json(uuid, timestamptz, timestamptz) rename to owner_portal_bookings_json_pre3810;
create function app.owner_portal_bookings_json(p_by uuid, p_from timestamptz default null, p_to timestamptz default null) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(jsonb_agg(x || case when x ->> 'owner_view' = 'full' then app.owner_booking_money((x ->> 'booking_id')::uuid)
                                      else jsonb_build_object('presumed_out', (select app.booking_pickup_unrecorded(b) from bookings b where b.id = (x ->> 'booking_id')::uuid)) end
                            order by n), '[]'::jsonb)
    from jsonb_array_elements(app.owner_portal_bookings_json_pre3810(p_by, p_from, p_to)) with ordinality t(x, n)
$$;
select pg_temp.copy_grants('app.owner_portal_bookings_json(uuid, timestamptz, timestamptz)'::regprocedure, 'app.owner_portal_bookings_json_pre3810(uuid, timestamptz, timestamptz)'::regprocedure);

-- ================================================================ 2. pickup not recorded, car presumed out
-- The booking that keeps a car out past its return time: confirmed, its pickup passed, no handover recorded (and no later
-- rental of the same car went out, app.booking_is_out). From now on, until it is recorded.
create function app.vehicle_presumed_out(p_vehicle uuid, p_ignore_booking uuid default null, p_now timestamptz default now()) returns bookings
language sql stable security definer set search_path = public, app, pg_temp as $$
  select b.* from bookings b
   where b.vehicle_id = p_vehicle and b.status = 'confirmed' and b.return_at <= p_now and b.booking_type <> 'owner'
     and (p_ignore_booking is null or b.id <> p_ignore_booking) and app.booking_pickup_unrecorded(b, p_now)
   order by b.pickup_at desc limit 1
$$;

alter function app.vehicle_is_available(uuid, timestamptz, timestamptz, uuid) rename to vehicle_is_available_pre3810;
create function app.vehicle_is_available(p_vehicle uuid, p_from timestamptz, p_to timestamptz, p_ignore_booking uuid default null) returns boolean
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  if not app.vehicle_is_available_pre3810(p_vehicle, p_from, p_to, p_ignore_booking) then return false; end if;
  -- presumed out: busy from now until its handover, return or no-show is recorded
  return not (p_to > now() and (app.vehicle_presumed_out(p_vehicle, p_ignore_booking)).id is not null);
end $$;
select pg_temp.copy_grants('app.vehicle_is_available(uuid, timestamptz, timestamptz, uuid)'::regprocedure, 'app.vehicle_is_available_pre3810(uuid, timestamptz, timestamptz, uuid)'::regprocedure);

alter function app.booking_date_conflicts(uuid) rename to booking_date_conflicts_pre3810;
create function app.booking_date_conflicts(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v jsonb := app.booking_date_conflicts_pre3810(p_booking);
  b bookings;
  o bookings;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null or b.return_at <= now() then return v; end if;
  o := app.vehicle_presumed_out(b.vehicle_id, b.id);
  if o.id is null or exists (select 1 from jsonb_array_elements(v) x where x ->> 'id' = o.id::text) then return v; end if;
  return v || jsonb_build_array(jsonb_build_object('type', 'booking', 'id', o.id, 'booking_number', o.booking_number, 'status', o.status,
    'pickup_at', o.pickup_at, 'return_at', o.return_at, 'starts_at', o.pickup_at, 'ends_at', null, 'kind', 'presumed_out', 'placeholder', false,
    'holds', true, 'blocks', true, 'note', 'Pickup not recorded, car presumed out: record the handover, the return or a no-show first',
    'renter', (select split_part(btrim(r.legal_name), ' ', 1) from renters r where r.id = o.renter_id)));
end $$;
select pg_temp.copy_grants('app.booking_date_conflicts(uuid)'::regprocedure, 'app.booking_date_conflicts_pre3810(uuid)'::regprocedure);

-- Fleet records the handover (then the Admins, once the return time passed): a To do per booking, until it is recorded
create function app.job_presumed_out(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  r record;
  n integer := 0;
begin
  for r in select b.id, b.booking_number, b.vehicle_id, b.pickup_at, b.return_at from bookings b
            where b.status = 'confirmed' and b.booking_type <> 'owner' and b.pickup_at <= p_now - interval '1 hour'
              and b.pickup_at > p_now - interval '60 days' and app.booking_pickup_unrecorded(b, p_now) loop
    perform app.raise_task(p_type => 'pickup_unrecorded', p_queue => 'fleet', p_booking => r.id, p_vehicle => r.vehicle_id,
      p_title => format('Pickup not recorded, car presumed out: %s', r.booking_number),
      p_detail => format('%s was due out %s and nobody recorded the handover. The car counts as out (no new offer or booking on it) until you record the handover, the return or a no-show.',
                         app.vehicle_name(r.vehicle_id), app.fmt_date(r.pickup_at)),
      p_dedupe => 'presumed_out:' || r.id);
    if r.return_at <= p_now then
      perform app.raise_task(p_type => 'pickup_unrecorded_admin', p_queue => 'admin', p_booking => r.id, p_vehicle => r.vehicle_id,
        p_title => format('Car presumed out past its return: %s', r.booking_number),
        p_detail => format('%s: the pickup was never recorded and the return time (%s) passed. Record the handover and the return, or a no-show, so the car can be offered again.',
                           app.vehicle_name(r.vehicle_id), app.fmt_date(r.return_at)),
        p_dedupe => 'presumed_out_admin:' || r.id);
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

-- ================================================================ 3. Form D copies filed with the owner's image in Part 2
-- (the renderer is fixed in the website; these copies are filed again by the pdf job of each)
create temp table r50_reissue on commit drop as
  select r.id, r.owner_id, r.title, r.signed_document_id from sign_requests r
    join pdf_jobs j on j.kind = 'sign_request_record' and j.ref = r.id
   where r.doc_type = 'form_d' and r.status = 'signed' and r.signed_document_id is not null and nullif(j.payload ->> 'drawn_path', '') is not null;
update documents d set removed_at = now(), removed_reason = 'Replaced (3810): Part 2 printed the owner''s signature instead of the CarmaCars countersignature; filed again'
  from r50_reissue x where d.id = x.signed_document_id and d.removed_at is null;
update signature_requests s set signed_document_id = null from sign_requests r join r50_reissue x on x.id = r.id where s.id = r.signature_request_id;
update sign_requests r set signed_document_id = null from r50_reissue x where r.id = x.id;
update pdf_jobs j set status = 'queued', attempts = 0, next_attempt_at = now(), done_at = null, locked_at = null, locked_by = null, last_error = null
  from r50_reissue x where j.kind = 'sign_request_record' and j.ref = x.id;

-- ================================================================ 4. the Onboarding Method, changed by an Admin
-- p: vehicle_id, method (co_registrant | transfer | lease_existing_corporation | lease_new_owner_corporation), reason,
-- preview (true: what would change, nothing changed). Refused once the car's Vehicle Schedule is signed (a new schedule then).
create function app.set_onboarding_method(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v vehicles;
  ob vehicle_onboardings;
  s vehicle_schedules;
  v_method text := lower(btrim(coalesce(p ->> 'method', '')));
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_mode management_mode;
  v_plan jsonb;
  v_forms jsonb;
begin
  perform app.assert_admin(p_by);
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  select * into ob from vehicle_onboardings where vehicle_id = v.id for update;
  if ob.id is null then raise exception 'This car has no onboarding record' using errcode = 'P0002'; end if;
  select * into s from vehicle_schedules where vehicle_id = v.id and superseded_by is null for update;
  v_mode := coalesce(s.management_mode, ob.proposed_management_mode, v.management_mode);
  if v_method not in ('co_registrant', 'transfer', 'lease_existing_corporation', 'lease_new_owner_corporation', 'none') then
    raise exception 'method: co_registrant, transfer, lease_existing_corporation or lease_new_owner_corporation' using errcode = '22023';
  end if;
  if not exists (select 1 from app.onboarding_options(ob.held_by, ob.title_status, v_mode) o where o.method::text = v_method) then
    raise exception 'That method is not available for this car (held by %, %, %)', ob.held_by, replace(ob.title_status::text, '_', ' '), replace(v_mode::text, '_', ' ') using errcode = '23514';
  end if;
  if s.signed_at is not null then
    raise exception 'This car''s Vehicle Schedule is signed: the method changes with a new signed Vehicle Schedule (propose a schedule change)' using errcode = '23514';
  end if;
  if v_reason is null or length(v_reason) < 5 then raise exception 'reason: why the method changes (5 characters or more)' using errcode = '22023'; end if;
  v_plan := app.onboarding_plan(ob.held_by, ob.title_status, v_mode, v_method::onboarding_method, coalesce(ob.owners_lien_elected, false));
  if coalesce((p ->> 'preview')::boolean, false) then
    return jsonb_build_object('preview', true, 'vehicle', app.vehicle_name(v.id), 'schedule', s.schedule_number,
      'from', coalesce(s.onboarding_method::text, ob.proposed_onboarding_method::text, v.onboarding_method::text), 'to', v_method,
      'government_forms', v_plan -> 'government_forms', 'estimate_cents', v_plan -> 'estimate_cents');
  end if;
  update vehicle_onboardings
     set proposed_onboarding_method = v_method::onboarding_method, situation = v_plan ->> 'situation',
         government_forms = coalesce((select array_agg(f) from jsonb_array_elements_text(v_plan -> 'government_forms') f), '{}'),
         sign_back_on_permit = (v_plan ->> 'sign_back_on_permit')::boolean,
         estimate_cents = (v_plan ->> 'estimate_cents')::bigint, estimate_plus_tax = (v_plan ->> 'estimate_plus_tax')::boolean
   where id = ob.id;
  update vehicles set onboarding_method = v_method::onboarding_method where id = v.id;
  if s.id is not null then
    update vehicle_schedules set onboarding_method = v_method::onboarding_method, onboarding_estimate_cents = (v_plan ->> 'estimate_cents')::bigint where id = s.id;
  end if;
  -- the government forms of the new method, made again (a form signed or filed keeps its values)
  if app.registry_forms_due(v.id) then
    begin
      v_forms := app.registry_forms_refresh(v.id, p_by, true);
    exception when others then
      v_forms := jsonb_build_object('error', sqlerrm);
    end;
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'set_onboarding_method', 'vehicles', v.id::text, jsonb_build_object('method', coalesce(s.onboarding_method::text, ob.proposed_onboarding_method::text)),
          jsonb_build_object('method', v_method, 'reason', v_reason, 'schedule', s.schedule_number, 'forms', v_forms));
  return jsonb_build_object('done', true, 'vehicle', app.vehicle_name(v.id), 'schedule', s.schedule_number, 'method', v_method,
    'government_forms', v_plan -> 'government_forms', 'forms', v_forms);
end $$;

-- ================================================================ 5. the door and the connector
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3810;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if p_call in ('ops_do', 'admin_do') and p_name = 'set_onboarding_method' then
    perform app.door_begin(p_user, p_aal);
    return app.set_onboarding_method(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre3810(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3810(uuid, text, text, text, jsonb)'::regprocedure);

alter function app.api_call(text, text, jsonb, text) rename to api_call_pre3810;
create function app.api_call(p_hash text, p_tool text, p_args jsonb, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  a jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  chk jsonb;
  k api_keys;
  v_args jsonb;
  v_confirm boolean;
  pv api_previews;
  v_result jsonb;
  v_target text := left(coalesce(nullif(a ->> 'vehicle_id', ''), p_tool), 200);
begin
  if p_tool <> 'set_onboarding_method' then return app.api_call_pre3810(p_hash, p_tool, p_args, p_client); end if;
  chk := app.api_key_check(p_hash, 'admin:write', p_tool, a, p_client);
  if not (chk ->> 'ok')::boolean then return chk; end if;
  k := jsonb_populate_record(null::api_keys, chk -> 'key');
  perform app.door_begin(k.user_id, 'aal2');
  v_confirm := coalesce((a ->> 'confirm')::boolean, false);
  v_args := a - 'confirm' - 'preview_id';
  begin
    if not v_confirm then
      v_result := app.set_onboarding_method(k.user_id, v_args || jsonb_build_object('preview', true));
      insert into api_previews (key_id, user_id, tool, args, before, after)
      values (k.id, k.user_id, p_tool, v_args, jsonb_build_object('method', v_result -> 'from'), jsonb_build_object('method', v_result -> 'to', 'government_forms', v_result -> 'government_forms'))
      returning * into pv;
      v_result := v_result || jsonb_build_object('preview_id', pv.id, 'tool', p_tool, 'expires_at', pv.created_at + interval '10 minutes',
        'next', 'Nothing was changed. To change it, call this tool again with exactly the same arguments plus "confirm": true and "preview_id": "' || pv.id || '".');
    else
      select * into pv from api_previews where id = nullif(a ->> 'preview_id', '')::uuid for update;
      if pv.id is null or pv.key_id <> k.id or pv.tool <> p_tool then raise exception 'Preview first: call without confirm, then confirm with its preview_id' using errcode = '22023'; end if;
      if pv.used_at is not null then raise exception 'This preview was already used: preview again' using errcode = '22023'; end if;
      if pv.created_at < now() - interval '10 minutes' then raise exception 'This preview is more than 10 minutes old: preview again' using errcode = '22023'; end if;
      if pv.args is distinct from v_args then raise exception 'The arguments differ from the preview: preview again with these' using errcode = '22023'; end if;
      update api_previews set used_at = now() where id = pv.id;
      v_result := app.set_onboarding_method(k.user_id, v_args);
    end if;
  exception when others then
    insert into api_calls (key_id, user_id, tool, target, args, ok, error, client) values (k.id, k.user_id, p_tool, v_target, v_args, false, left(sqlerrm, 500), left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', case sqlstate when 'P0002' then 404 when '42501' then 403 else 400 end, 'error', regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''));
  end;
  insert into api_calls (key_id, user_id, tool, target, args, ok, client)
  values (k.id, k.user_id, case when not v_confirm then p_tool || ':preview' else p_tool end, v_target, v_args, true, left(p_client, 64));
  return jsonb_build_object('ok', true, 'result', v_result);
end $$;
select pg_temp.copy_grants('app.api_call(text, text, jsonb, text)'::regprocedure, 'app.api_call_pre3810(text, text, jsonb, text)'::regprocedure);

-- ================================================================ 6. the notice
-- CATALOGUE 3810 START (generated by supabase/seed/3810_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('owner_document_reissued', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'We corrected your signed {{document_title}}', 'The CarmaCars countersignature is fixed. Nothing changes for you.', 'Once, when the corrected copy is filed', 'Release 50 (migration 3810), once: a signed copy of the owner''s Form D (or another countersigned document) was filed with the owner''s drawn signature in the part CarmaCars signs. The copy is filed again with the correct CarmaCars countersignature; the owner''s signature and the text are unchanged.', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"document_title","type":"string"},{"name":"documents_url","type":"url"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"what","type":"string"}]'::jsonb, 'templates/owner_document_reissued.html', 'templates/owner_document_reissued.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 3810 END
update notification_catalogue set emitted_by = '3810 (once): a Form D filed with the owner''s image in its CarmaCars part, filed again', push_topic = 'documents', no_text = true
 where code = 'owner_document_reissued';
insert into app_events (code, entity, entity_id, payload, dedupe_key)
select 'owner_document_reissued', 'owner', x.owner_id, jsonb_build_object('owner_id', x.owner_id, 'first_name', app.owner_first_name(o),
         'document_title', coalesce(x.title, 'Form D'),
         'what', 'Part 2, which CarmaCars signs, showed your signature instead of the CarmaCars countersignature. Your own signature and everything you signed are unchanged.',
         'documents_url', rtrim(coalesce((app.settings()).notify_base_url, 'https://carmacars.ca'), '/') || '/owner/documents'),
       'owner_document_reissued:' || x.id
  from r50_reissue x join owners o on o.id = x.owner_id
on conflict (dedupe_key) do nothing;

-- ================================================================ 7. data fix: VS-1012 is a Transfer
do $$
declare
  s vehicle_schedules;
  v_admin uuid := (select u.id from users u join user_roles r on r.user_id = u.id and r.role = 'admin' where u.status = 'active' order by u.created_at limit 1);
begin
  select * into s from vehicle_schedules where schedule_number = 'VS-1012' and vehicle_id::text like '7315bf3e%' and superseded_by is null;
  if s.id is null or s.signed_at is not null or s.onboarding_method = 'transfer' or v_admin is null then return; end if;
  perform app.set_onboarding_method(v_admin, jsonb_build_object('vehicle_id', s.vehicle_id, 'method', 'transfer',
    'reason', 'The car is transferred to the owner, not co-registered (the owner''s report of November 24, 2026; migration 3810)'));
exception when others then
  raise warning 'VS-1012 onboarding method not changed: %', sqlerrm;
end $$;

-- ================================================================ 8. the schedule, privileges
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['owner_booking_money', 'vehicle_presumed_out', 'job_presumed_out', 'set_onboarding_method',
              'owner_portal_bookings_json_pre3810', 'vehicle_is_available_pre3810', 'booking_date_conflicts_pre3810', 'door_pre3810', 'api_call_pre3810']) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron is not available here: the presumed-out job is not scheduled';
    return;
  end if;
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise warning 'pg_cron could not be created in this database (%): the presumed-out job is not scheduled', sqlerrm;
    return;
  end;
  perform cron.schedule('carmacars-r50-presumed-out', '*/15 * * * *', $q$select app.job_presumed_out()$q$);
end $$;
