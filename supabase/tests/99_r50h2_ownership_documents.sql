-- R50 hotfix 2 (5144): ownership permits uploaded in bulk: each filed on its car by an exact VIN only (a plate only suggests the
-- car for a person to confirm: review fix), as the
-- car's ownership permit (shown in the owner's portal, the owner told); one not matched waits for a person with one Fleet To
-- do, then is filed by hand or set aside with the reason. Fixtures start with "pm5".
select test.suite('99 r50h2 ownership documents');
select test.mk_user('pm5_fleet', 'va', 'fleet');
select test.mk_user('pm5_fin', 'va', 'finance');
select test.mk_owner('pm5_oprah');
select test.mk_vehicle('PM5A', 'pm5_oprah');
select test.mk_vehicle('PM5B', 'pm5_oprah');
create table test.pm5 (k text primary key, v jsonb);
create function test.pm5v(p text) returns jsonb language sql stable as $$ select v from test.pm5 where k = p $$;
create function test.pm5f(n integer, p jsonb) returns jsonb language sql immutable as $$ select jsonb_build_object('path', 'permits/2026/' || md5('pm5' || n)::uuid || '.jpg', 'mime', 'image/jpeg', 'file_name', 'permit-' || n || '.jpg') || p $$;

select test.throws('who: Finance does not file a car''s documents', format('select app.permit_file(%L, %L)', test.id('pm5_fin'), test.pm5f(0, '{}')), 'Fleet or customer service');
select test.throws('file: a key the server built', format('select app.permit_file(%L, %L)', test.id('pm5_fleet'), jsonb_build_object('path', 'documents/x.jpg')), 'Unknown permit file');

insert into test.pm5 select 'vin', app.permit_file(test.id('pm5_fleet'), test.pm5f(1, jsonb_build_object('vin', lower((select vin from vehicles where id = test.id('vehicle:PM5A'))), 'plate', 'ZZZZ 999')));
insert into test.pm5 select 'plate', app.permit_file(test.id('pm5_fleet'), test.pm5f(2, jsonb_build_object('plate', (select lower(plate) from vehicles where id = test.id('vehicle:PM5B')))));
insert into test.pm5 select 'none', app.permit_file(test.id('pm5_fleet'), test.pm5f(3, jsonb_build_object('vin', '1HGCM82633A004352', 'plate', 'QQQQ111')));
insert into test.pm5 select 'blank', app.permit_file(test.id('pm5_fleet'), test.pm5f(4, '{}'));
select test.eq('match: filed by the VIN (any case); the plate alone only suggests its car and waits; none; nothing read',
  concat_ws(' ', (test.pm5v('vin') ->> 'status') || ':' || (test.pm5v('vin') ->> 'matched_by') || ':' || ((test.pm5v('vin') ->> 'vehicle_id')::uuid = test.id('vehicle:PM5A')),
                 (test.pm5v('plate') ->> 'status') || ':' || ((test.pm5v('plate') ->> 'suggested_vehicle_id')::uuid = test.id('vehicle:PM5B')),
                 test.pm5v('none') ->> 'status', test.pm5v('blank') ->> 'status'),
  'filed:vin:true unmatched:true unmatched unmatched');
select test.eq('plate only: nothing filed on the car, no document on it, the owner not emailed for it',
  (select count(*) from permit_uploads where id = (test.pm5v('plate') ->> 'upload')::uuid and vehicle_id is null and status = 'unmatched')::text || '/' ||
  (select count(*) from documents d where d.vehicle_id = test.id('vehicle:PM5B') and d.kind = 'ownership_permit')::text, '1/0');
select test.eq('match: a VIN match whose plate is not the car''s says so', (select position('is not the car''s plate' in note) > 0 from permit_uploads where id = (test.pm5v('vin') ->> 'upload')::uuid), true);
select test.eq('filed: the car''s ownership permit, on the car and its owner, in the owner''s portal',
  (select d.kind || '/' || (d.vehicle_id = test.id('vehicle:PM5A')) || '/' || (d.owner_id = test.id('owner:pm5_oprah')) from documents d where d.id = (test.pm5v('vin') ->> 'document_id')::uuid) || '/' ||
  (select count(*) from jsonb_array_elements(app.owner_portal_documents((select user_id from owners where id = test.id('owner:pm5_oprah')))) x where x ->> 'kind' = 'ownership_permit'),
  'ownership_permit/true/true/1');
select test.eq('filed: the owner is told once (the VIN match only)', (select count(*) from app_events e where e.code = 'owner_permit_filed' and e.payload ->> 'owner_id' = test.id('owner:pm5_oprah')::text), 1::bigint);
select test.eq('waiting: one Fleet To do counts the files without a car', (select queue || '/' || title from tasks where dedupe_key = 'permit_unmatched' and status = 'open'), 'fleet/3 ownership documents need a car');
select test.eq('waiting: listed with why, the plate''s car suggested', (select string_agg(regexp_replace(x ->> 'note', 'the .* the VIN', 'the CAR, the VIN'), ' | ' order by x ->> 'created_at') || '/' ||
    count(*) filter (where (x ->> 'suggested_vehicle_id')::uuid = test.id('vehicle:PM5B')) from jsonb_array_elements(app.permit_uploads_json(test.id('pm5_fleet')) -> 'waiting') x),
  'The plate matches the CAR, the VIN did not: confirm the car | No car has this VIN or plate: pick the car | No VIN or plate could be read: pick the car/1');
select app.permit_assign(test.id('pm5_fleet'), jsonb_build_object('upload', test.pm5v('plate') ->> 'upload', 'vehicle_id', test.id('vehicle:PM5B')));
select test.eq('confirmed: the suggested car filed by a person', (select status || ':' || matched_by || ':' || (vehicle_id = test.id('vehicle:PM5B')) from permit_uploads where id = (test.pm5v('plate') ->> 'upload')::uuid), 'filed:hand:true');
select app.permit_assign(test.id('pm5_fleet'), jsonb_build_object('upload', test.pm5v('none') ->> 'upload', 'vehicle_id', test.id('vehicle:PM5B')));
select test.eq('by hand: filed on the car picked; the To do counts one', (select status || ':' || matched_by from permit_uploads where id = (test.pm5v('none') ->> 'upload')::uuid) || '/' ||
  (select title from tasks where dedupe_key = 'permit_unmatched' and status = 'open'), 'filed:hand/1 ownership document needs a car');
select test.throws('aside: needs the reason', format('select app.permit_discard(%L, %L)', test.id('pm5_fleet'), jsonb_build_object('upload', test.pm5v('blank') ->> 'upload')), 'Say why');
select app.permit_discard(test.id('pm5_fleet'), jsonb_build_object('upload', test.pm5v('blank') ->> 'upload', 'reason', 'Not a permit: an insurance slip'));
select test.eq('aside: nothing waits; the To do is done', (select jsonb_array_length(app.permit_uploads_json(test.id('pm5_fleet')) -> 'waiting'))::text || '/' ||
  (select status from tasks where dedupe_key = 'permit_unmatched'), '0/done');
select test.throws('once: a filed file is not filed again', format('select app.permit_assign(%L, %L)', test.id('pm5_fleet'), jsonb_build_object('upload', test.pm5v('vin') ->> 'upload', 'vehicle_id', test.id('vehicle:PM5B'))), 'already filed');
select test.eq('door: through ops_do permit_file', (app.door(test.id('pm5_fleet'), 'aal2', 'ops_do', 'permit_file', test.pm5f(5, jsonb_build_object('vin', (select vin from vehicles where id = test.id('vehicle:PM5B'))))) ->> 'matched_by'), 'vin');

select app.process_events(100000);
select test.eq('email: the owner''s emails are built: no variable missing',
  (select count(*) filter (where o.missing_variables = '{}') || '/' || count(*) from notification_outbox o where o.code = 'owner_permit_filed' and coalesce(o.channel, 'email') = 'email'
      and o.entity_id = test.id('owner:pm5_oprah')) <> '0/0' and not exists (select 1 from notification_outbox o where o.code = 'owner_permit_filed' and o.missing_variables <> '{}'), true);
