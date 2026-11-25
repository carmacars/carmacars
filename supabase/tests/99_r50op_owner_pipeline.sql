-- 99: the owner pipeline (migrations 4510 to 4512, docs/changes/2026-11-24-r50-owner-pipeline.md): one stage tracker per
-- owner and car, one next action for the right person, nudges, To dos, the stall alert, Admin overrides, the incorporation
-- referral. Fixtures "op50".
select test.suite('99 r50 owner pipeline: stages per route, the next action, notices and To dos, overrides, incorporation referral');
select test.mk_user('op50_admin', 'admin');
select test.mk_user('op50_fleet', 'va', 'fleet');
select test.mk_user('op50_sales', 'va', 'sales');
select test.mk_user('op50_sales2', 'va', 'sales');
create function test.op50(p_call text, p_name text, p jsonb, p_user text default 'op50_admin') returns jsonb language sql as $$ select app.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;
create function test.op50_owner(p_label text, p_type text default 'individual') returns uuid language plpgsql as $$
declare v_user uuid := test.mk_user(p_label, 'owner');
begin
  update users set email = p_label || '@example.test' where id = v_user;
  insert into owners (id, user_id, owner_type, legal_name, first_name, last_name, status, email, phone, address_line1, city, province, postal_code, country,
                      corporation_name, corporation_number, signing_officer_name, signing_officer_title, recruited_by)
  values (test.id('owner:' || p_label), v_user, p_type::owner_type, initcap(replace(p_label, '_', ' ')), 'Pat', 'Example', 'active', p_label || '@example.test', '+16475550188',
          '1 Example Way', 'Toronto', 'ON', 'M5V 1A1', 'CA',
          case when p_type = 'corporation' then 'Op Holdings Ltd.' end, case when p_type = 'corporation' then '1000188' end,
          case when p_type = 'corporation' then 'Pat Example' end, case when p_type = 'corporation' then 'Director' end, test.id('op50_sales'));
  return test.id('owner:' || p_label);
end $$;
create function test.op50_car(p_owner text, p_vin text, p_method text) returns uuid language plpgsql as $$
declare r jsonb;
begin
  r := app.submit_owner_application(jsonb_build_object('owner_id', test.id('owner:' || p_owner), 'source', 'web', 'vehicles', jsonb_build_array(jsonb_build_object(
         'vin', p_vin, 'plate', 'P' || right(p_vin, 6), 'year', 2021, 'make', 'Hyundai', 'model', 'Sonata', 'colour', 'Blue', 'odometer_km', 20000,
         'held_by', (select owner_type from owners where id = test.id('owner:' || p_owner)), 'title_status', 'owned_outright', 'management_mode', 'managed',
         'onboarding_method', p_method, 'current_insurer', 'Example Insurer',
         'new_corporation', case when p_method = 'lease_new_owner_corporation' then jsonb_build_object('proposed_name', 'numbered') end))), test.id(p_owner));
  return (r #>> '{vehicles,0,vehicle_id}')::uuid;
end $$;
create function test.op50_approve(p_vehicle uuid, p_method text) returns void language plpgsql as $$
begin
  perform app.application_approve(test.id('op50_admin'), jsonb_build_object('id', (select application_id from vehicle_onboardings where vehicle_id = p_vehicle),
    'cars', jsonb_build_array(jsonb_build_object('vehicle_id', p_vehicle, 'terms', jsonb_build_object('management_mode', 'managed', 'onboarding_method', p_method),
      'invoices', '[]'::jsonb, 'first_last', jsonb_build_object('action', 'none')))));
end $$;
create function test.op50_doc(p_vehicle uuid, p_kind text, p_review text default 'approved') returns uuid language sql as $$
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, retention, owner_id, vehicle_id, review_status, review_note)
  select p_kind::document_kind, p_kind, 'documents', 'owners/x/' || gen_random_uuid() || '.jpg', 'image/jpeg', repeat('b', 64), 'records_7y', v.owner_id, v.id, p_review,
         case when p_review = 'rejected' then 'Blurry: the numbers cannot be read' end
    from vehicles v where v.id = p_vehicle returning id $$;
create function test.op50_stage(p_vehicle uuid) returns text language sql stable as $$
  select coalesce(app.owner_stage_track(p_vehicle) ->> 'stage', 'finished') || '/' || coalesce(app.owner_stage_track(p_vehicle) ->> 'actor', '-') $$;
create function test.op50_codes(p_vehicle uuid) returns text language sql stable as $$
  select string_agg(x ->> 'code', ',' order by n) from jsonb_array_elements(app.owner_stage_track(p_vehicle) -> 'stages') with ordinality t(x, n) $$;
create function test.op50_events(p_code text, p_owner uuid) returns bigint language sql stable as $$
  select count(*) from app_events where code = p_code and (entity_id = p_owner or payload ->> 'owner_id' = p_owner::text) $$;

-- ================================================================ 1. settings and wording
select test.eq('the stall alert waits 3 days by default, notices on', (select owner_stage_stall_days || '/' || owner_stage_enabled from program_settings order by effective_from desc limit 1), '3/true');
select test.eq('ten stages, each with its call script and expected time', (select count(*) filter (where call_script <> '' and expected <> '') from owner_stage_defs), 10::bigint);
select test.eq('the incorporation referral ships off, with Ownr and its sign-up page', (select enabled || '/' || provider_name || '/' || signup_url from incorporation_affiliate), 'false/Ownr/https://www.ownr.co/affiliates');

-- ================================================================ 2. the Transfer route, end to end
select test.op50_owner('op50_pat');
create temporary table op50v as select test.op50_car('op50_pat', 'KMHL14JA0MA340888', 'transfer') as v;
select test.eq('Transfer: nine stages (title to the company)', test.op50_codes((select v from op50v)),
  'application,terms,agreements,documents,transfer,registration,fleet_policy,inspection,listed');
select test.eq('applied, not approved: Terms approved waits on an Admin', test.op50_stage((select v from op50v)), 'terms/admin');
select test.eq('the Admin''s action opens the application', (app.owner_stage_track((select v from op50v)) #>> '{current,action,admin,href}') like '/admin/applications/%', true);
select app.owner_stage_refresh((select v from op50v));
select test.eq('the car is in the pipeline, at its stage', (select stage || '/' || actor || '/' || route from owner_pipeline where vehicle_id = (select v from op50v)), 'terms/admin/transfer');
select test.eq('an Admin To do for the terms', (select count(*) from tasks where vehicle_id = (select v from op50v) and task_type = 'owner_stage_turn' and queue = 'admin' and status = 'open'), 1::bigint);
select test.op50_approve((select v from op50v), 'transfer');
select app.owner_stage_refresh((select v from op50v));
select test.eq('approved: Agreements signed, the owner''s turn', test.op50_stage((select v from op50v)), 'agreements/owner');
select test.eq('the Admin''s To do closed by itself', (select string_agg(status, ',') from tasks where vehicle_id = (select v from op50v) and task_type = 'owner_stage_turn' and queue = 'admin'), 'done');
select test.eq('the owner is told it is their turn (email and text), once', test.op50_events('owner_stage_your_turn', test.id('owner:op50_pat')), 1::bigint);
select app.owner_stage_refresh((select v from op50v));
select test.eq('refreshing again tells nobody twice', test.op50_events('owner_stage_your_turn', test.id('owner:op50_pat')), 1::bigint);
select test.eq('the owner''s action is to sign', (app.owner_stage_track((select v from op50v)) #>> '{current,action,owner,label}'), 'Sign your agreements');
-- the e-signature itself is tested elsewhere (99_esign_everywhere, 99_r50ow_sign_first); an Admin advances it here
select test.throws('advancing needs a reason', format($$select test.op50('admin_do', 'owner_stage_do', '{"vehicle_id": "%s", "op": "advance"}')$$, (select v from op50v)), 'Say why%');
select test.throws('only an Admin overrides a stage', format($$select test.op50('va_do', 'owner_stage_do', '{"vehicle_id": "%s", "op": "advance", "note": "x"}', 'op50_fleet')$$, (select v from op50v)), 'Only an Admin%');
select test.lives('an Admin advances Agreements signed', format($$select test.op50('admin_do', 'owner_stage_do', '{"vehicle_id": "%s", "op": "advance", "note": "Signed on paper at the office"}')$$, (select v from op50v)));
select test.eq('the override is in the audit log with its reason', (select after ->> 'note' from audit_log where action = 'owner_stage_override' and entity_id = (select v from op50v)::text order by at desc, id desc limit 1), 'Signed on paper at the office');
select test.eq('now Documents uploaded, the owner''s turn', test.op50_stage((select v from op50v)), 'documents/owner');
select test.eq('the owner is asked for the licence, the ownership permit and the insurance',
  (select string_agg(i ->> 'kind', ',') from jsonb_array_elements(app.owner_stage_track((select v from op50v)) #> '{current,items}') i), 'owner_id,ownership_permit,owner_insurance_proof');
select test.op50_doc((select v from op50v), 'owner_id', 'rejected');
select test.eq('a document not accepted is a blocker in plain words',
  (app.owner_stage_track((select v from op50v)) #>> '{current,blockers,0}'), 'Driver''s licence not accepted: Blurry: the numbers cannot be read. Upload it again.');
update documents set removed_at = now() where vehicle_id = (select v from op50v) and kind = 'owner_id';
select test.op50_doc((select v from op50v), 'owner_id', 'waiting');
select test.op50_doc((select v from op50v), 'ownership_permit');
select test.op50_doc((select v from op50v), 'owner_insurance_proof');
select test.eq('everything uploaded, one being checked: Fleet''s turn', test.op50_stage((select v from op50v)), 'documents/fleet');
update documents set review_status = 'approved' where vehicle_id = (select v from op50v) and kind = 'owner_id' and removed_at is null;
select test.eq('approved: Ownership transfer, the owner''s turn', test.op50_stage((select v from op50v)), 'transfer/owner');
select test.eq('the transfer names what to bring, where to go (the centre finder) and the time',
  (select (t ->> 'bring' like '%Form A%') || '/' || (t ->> 'where_url') || '/' || (t ->> 'expected') from (select app.owner_stage_track((select v from op50v)) -> 'current' t) x),
  'true/https://www.ontario.ca/locations/serviceontario/30 to 60 minutes at the counter');
select test.eq('who pays the registry: the owner at the counter, as the terms say', (app.owner_stage_track((select v from op50v)) ->> 'fees_payer') like 'You pay the registry%', true);
select test.eq('the UVIP and the safety certificate are blockers until they are there',
  (select count(*) from jsonb_array_elements_text(app.owner_stage_track((select v from op50v)) #> '{current,blockers}') b where b like '%Used Vehicle Information Package%' or b like '%Safety Standards Certificate%'), 2::bigint);
select test.lives('Fleet says this transfer needs no UVIP', format($$select test.op50('va_do', 'owner_stage_do', '{"vehicle_id": "%s", "op": "needs", "uvip_needed": false, "note": "Family transfer"}', 'op50_fleet')$$, (select v from op50v)));
select test.eq('no UVIP item any more', (select count(*) from jsonb_array_elements(app.owner_stage_track((select v from op50v)) #> '{current,items}') i where i ->> 'kind' = 'uvip'), 0::bigint);
select test.throws('another salesperson''s owner is refused', format($$select test.op50('va_do', 'owner_stage_do', '{"vehicle_id": "%s", "op": "nudge"}', 'op50_sales2')$$, (select v from op50v)), 'Not permitted%');
select test.throws('the owner cannot record the visit before saying the fees are paid', format($$select app.door(test.id('op50_pat'), 'aal1', 'ops_do', 'owner_stage_do', '{"vehicle_id": "%s", "op": "visited"}')$$, (select v from op50v)), 'Confirm the registry%');
select test.lives('the owner books the appointment', format($$select app.door(test.id('op50_pat'), 'aal1', 'ops_do', 'owner_stage_do', '{"vehicle_id": "%s", "op": "appointment", "at": "%s", "place": "ServiceOntario Scarborough"}')$$,
  (select v from op50v), (now() + interval '2 days')::text));
select test.eq('the appointment is on the onboarding', (select registry_place from vehicle_onboardings where vehicle_id = (select v from op50v)), 'ServiceOntario Scarborough');
select test.eq('the owner''s next action is to go, then press Transfer done', (app.owner_stage_track((select v from op50v)) #>> '{current,action,owner,op}'), 'visited');
select test.op50_doc((select v from op50v), 'safety_certificate');
select test.lives('the owner records the visit, fees paid', format($$select app.door(test.id('op50_pat'), 'aal1', 'ops_do', 'owner_stage_do', '{"vehicle_id": "%s", "op": "visited", "fees_paid": true}')$$, (select v from op50v)));
select test.eq('now New registration uploaded, the owner''s turn', test.op50_stage((select v from op50v)), 'registration/owner');
select test.op50_doc((select v from op50v), 'new_registration', 'waiting');
select test.eq('the new permit uploaded: Plate and insurance on the fleet policy, Fleet''s turn', test.op50_stage((select v from op50v)), 'fleet_policy/fleet');
select app.owner_stage_refresh((select v from op50v));
select test.eq('Fleet gets a To do for it', (select count(*) from tasks where vehicle_id = (select v from op50v) and task_type = 'owner_stage_turn' and queue = 'fleet' and status = 'open'), 1::bigint);
update vehicles set on_fleet_policy = true, fleet_policy_added_on = app.today() where id = (select v from op50v);
select test.eq('on the policy: Inspected and photographed, Fleet''s turn', test.op50_stage((select v from op50v)), 'inspection/fleet');
select test.throws('the owner cannot record the inspection', format($$select app.door(test.id('op50_pat'), 'aal1', 'ops_do', 'owner_stage_do', '{"vehicle_id": "%s", "op": "inspected"}')$$, (select v from op50v)), 'An Admin or Fleet%');
select test.lives('Fleet records the inspection', format($$select test.op50('va_do', 'owner_stage_do', '{"vehicle_id": "%s", "op": "inspected", "note": "Clean"}', 'op50_fleet')$$, (select v from op50v)));
select test.eq('inspected, the listing photos still to do: the stage stays', test.op50_stage((select v from op50v)), 'inspection/fleet');
select test.lives('an Admin sets the photos step done', format($$select test.op50('admin_do', 'owner_stage_do', '{"vehicle_id": "%s", "op": "set", "stage": "inspection", "status": "done", "note": "Photos done in the studio"}')$$, (select v from op50v)));
select test.eq('now Listed, an Admin''s turn', test.op50_stage((select v from op50v)), 'listed/admin');
select test.lives('an Admin advances the listing', format($$select test.op50('admin_do', 'owner_stage_do', '{"vehicle_id": "%s", "op": "advance", "note": "Published"}')$$, (select v from op50v)));
select test.eq('every stage done: the car leaves the pipeline', (select (finished_at is not null)::text from owner_pipeline where vehicle_id = (select v from op50v)), 'true');

-- ================================================================ 3. Sales: the board, the nudge, the stall alert
select test.op50_owner('op50_sam');
create temporary table op50w as select test.op50_car('op50_sam', 'KMHL14JA0MA340889', 'transfer') as v;
select test.op50_approve((select v from op50w), 'transfer');
select app.owner_stage_refresh((select v from op50w));
select test.eq('the salesperson''s board lists their owner''s car, with days in stage and the next action',
  (select c ->> 'stage' || '/' || (c ->> 'days_in_stage') || '/' || (c ->> 'next_action') from jsonb_array_elements(test.op50('va_read', 'owner_stage_board', '{}', 'op50_sales') -> 'cars') c
    where c ->> 'vehicle_id' = (select v from op50w)::text), 'agreements/0/Sign your agreements');
select test.eq('another salesperson does not see it', (select count(*) from jsonb_array_elements(test.op50('va_read', 'owner_stage_board', '{}', 'op50_sales2') -> 'cars') c where c ->> 'vehicle_id' = (select v from op50w)::text), 0::bigint);
select test.throws('the owner cannot read the board', $$select app.door(test.id('op50_sam'), 'aal1', 'ops_read', 'owner_stage_board', '{}')$$, 'Not permitted%');
select test.eq('the owner reads their own steps', (test.op50('ops_read', 'owner_stages', jsonb_build_object('owner_id', test.id('owner:op50_sam')), 'op50_sam') ->> 'viewer'), 'owner');
select test.lives('the salesperson nudges their owner', format($$select test.op50('va_do', 'owner_stage_do', '{"vehicle_id": "%s", "op": "nudge"}', 'op50_sales')$$, (select v from op50w)));
select test.eq('the nudge is a branded email and text, with the agent''s name', (select payload ->> 'agent' || '/' || (payload ->> 'stage_label') from app_events where code = 'owner_stage_nudge' and entity_id = test.id('owner:op50_sam')), 'Op50/Agreements signed');
select test.throws('once in 10 minutes a car', format($$select test.op50('va_do', 'owner_stage_do', '{"vehicle_id": "%s", "op": "nudge"}', 'op50_sales')$$, (select v from op50w)), 'A reminder went%');
update owner_pipeline set stage_since = now() - interval '4 days' where vehicle_id = (select v from op50w);
select app.owner_stage_sweep();
select test.eq('after 3 days the Admins are alerted, once', test.op50_events('staff_owner_stage_stalled', test.id('owner:op50_sam')), 1::bigint);
select test.eq('and the salesperson gets a To do', (select queue || '/' || (assigned_to = test.id('op50_sales')) from tasks where vehicle_id = (select v from op50w) and task_type = 'owner_stage_stalled' and status = 'open'), 'sales/true');
select app.owner_stage_sweep();
select test.eq('the next sweep alerts nobody again', test.op50_events('staff_owner_stage_stalled', test.id('owner:op50_sam')), 1::bigint);

-- ================================================================ 4. the lease routes
select test.op50_owner('op50_corp', 'corporation');
create temporary table op50c as select test.op50_car('op50_corp', 'KMHL14JA0MA340890', 'lease_existing_corporation') as v;
select test.eq('Lease of an existing corporation: no title transfer', test.op50_codes((select v from op50c)), 'application,terms,agreements,documents,fleet_policy,inspection,listed');
select test.op50_approve((select v from op50c), 'lease_existing_corporation');
select test.lives('advance the agreements', format($$select test.op50('admin_do', 'owner_stage_do', '{"vehicle_id": "%s", "op": "advance", "note": "Signed"}')$$, (select v from op50c)));
select test.eq('the corporation''s documents instead of the licence',
  (select string_agg(i ->> 'kind', ',') from jsonb_array_elements(app.owner_stage_track((select v from op50c)) #> '{current,items}') i), 'corporate_documents,ownership_permit,owner_insurance_proof');

select test.op50_owner('op50_ian');
create temporary table op50n as select test.op50_car('op50_ian', 'KMHL14JA0MA340891', 'lease_new_owner_corporation') as v;
select test.eq('Lease through a new Owner Corporation: Incorporate first', test.op50_codes((select v from op50n)), 'application,terms,incorporate,agreements,documents,fleet_policy,inspection,listed');
select test.op50_approve((select v from op50n), 'lease_new_owner_corporation');
select test.eq('incorporate: the owner''s turn', test.op50_stage((select v from op50n)), 'incorporate/owner');
select test.eq('the referral is off: the owner uploads the corporate documents, no provider is shown',
  (app.owner_stage_track((select v from op50n)) #>> '{current,action,owner,label}'), 'Upload your corporate documents');
select test.eq('off: the click goes nowhere and records nothing', public.server_incorporation_click(test.id('op50_ian'), jsonb_build_object('vehicle_id', (select v from op50n))) ->> 'ok', 'false');
select test.throws('only an Admin saves the link', $$select test.op50('va_do', 'incorporation_referral_save', '{"link_template": "https://x.example/a"}', 'op50_fleet')$$, null);
select test.throws('the link must be https', $$select test.op50('admin_do', 'incorporation_referral_save', '{"link_template": "http://x.example/a"}')$$, 'Paste the affiliate link%');
select test.lives('Abbas pastes his affiliate link', $$select test.op50('admin_do', 'incorporation_referral_save', '{"link_template": "https://www.ownr.co/?ref=abc&sub={ref}"}')$$);
select test.eq('pasting it turns the referral on', (select enabled from incorporation_affiliate), true);
select test.eq('now Incorporate now, through the tracked link', (select x ->> 'label' || '|' || (x ->> 'href') from (select app.owner_stage_track((select v from op50n)) #> '{current,action,owner}' x) y),
  'Incorporate now|/go/incorporate?v=' || (select v from op50n));
select test.eq('another owner''s click is refused', public.server_incorporation_click(test.id('op50_pat'), jsonb_build_object('vehicle_id', (select v from op50n))) ->> 'ok', 'false');
select test.eq('the owner''s click goes to the link with their code', public.server_incorporation_click(test.id('op50_ian'), jsonb_build_object('vehicle_id', (select v from op50n))) ->> 'url' ~ '^https://www\.ownr\.co/\?ref=abc&sub=CC[0-9A-F]{8}$', true);
select public.server_incorporation_click(test.id('op50_ian'), jsonb_build_object('vehicle_id', (select v from op50n)));
select test.eq('who was referred, for which car, how often', (select clicks || '/' || (vehicle_id = (select v from op50n)) || '/' || status from incorporation_referrals where owner_id = test.id('owner:op50_ian')), '2/true/clicked');
select test.throws('commission received needs the amount', format($$select test.op50('admin_do', 'incorporation_referral_mark', '{"id": "%s", "status": "commission_received"}')$$,
  (select id from incorporation_referrals where owner_id = test.id('owner:op50_ian'))), 'Enter the commission%');
select test.lives('the Admin records the commission', format($$select test.op50('admin_do', 'incorporation_referral_mark', '{"id": "%s", "status": "commission_received", "commission_cents": 5000}')$$,
  (select id from incorporation_referrals where owner_id = test.id('owner:op50_ian'))));
select test.eq('the referral report adds it up', (select x ->> 'referred' || '/' || (x ->> 'received_cents') from (select test.op50('admin_read', 'incorporation_referral', '{}') -> 'totals' x) y), '1/5000');
select test.op50_doc((select v from op50n), 'corporate_documents');
select test.eq('the corporate documents uploaded: Incorporate is done', test.op50_stage((select v from op50n)), 'agreements/owner');

-- ================================================================ 5. security
select test.eq('the new tables have row-level security and admin_all',
  (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname in ('owner_pipeline', 'owner_stage_defs', 'incorporation_affiliate', 'incorporation_referrals')
     and c.relrowsecurity and exists (select 1 from pg_policies p where p.tablename = c.relname and p.policyname = 'admin_all')), 4::bigint);
select test.eq('no browser role runs the new functions', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('app', 'public') and (p.proname like 'owner_stage%' or p.proname like 'incorporation%' or p.proname = 'server_incorporation_click')
    and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))), 0::bigint);
select test.eq('every new security definer function ends its search_path with pg_temp', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('app', 'public') and p.prosecdef and (p.proname like 'owner_stage%' or p.proname like 'incorporation_referral%' or p.proname = 'server_incorporation_click')
    and not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%pg_temp')), 0::bigint);
