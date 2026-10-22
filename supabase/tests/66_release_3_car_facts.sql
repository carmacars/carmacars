-- 66: release 3 (migration 0094), car facts and the games' re-show settings. A trim that is a list is never the trim
-- (its candidates are kept, Admin > Today asks which one, picking it saves it and the line is gone); an older vPIC
-- decode never fills the gearbox, a decode chosen from EPA's data does; the seats come from the body when the decoder
-- has none, and Admin > Today asks to confirm the gearbox and seats. Fixtures start with "cf".
select test.suite('66 release 3 car facts');

select test.mk_user('cf_admin', 'admin');
select test.mk_user('cf_cs', 'va', 'cs');
select test.mk_owner('cf_owner');
create or replace function test.cf_prompts() returns jsonb language sql as $$ select app.door(test.id('cf_admin'), '', 'ops_read', 'todo_prompts', '{}') $$;
create or replace function test.cf_prompt(p_key text) returns jsonb language sql as $$ select x from jsonb_array_elements(test.cf_prompts() -> 'prompts') x where x ->> 'key' = p_key $$;
select test.ok('Today: still the prompts and who is staffed', test.cf_prompts() ? 'prompts' and test.cf_prompts() ? 'staffed');

-- ---------------------------------------------------------------- 1. a trim that is a list
select test.eq('a list of trims: each once, in order', app.trim_list('S, Final Edition SE, Final Edition SEL, SE'), array['S', 'Final Edition SE', 'Final Edition SEL', 'SE']);
select test.eq('a list with slashes', app.trim_list('S / SE / R-Line'), array['S', 'SE', 'R-Line']);
select test.eq('a list with or', app.trim_list('FE or LXS'), array['FE', 'LXS']);
select test.ok('one trim is not a list', app.trim_list('EX-L') is null and app.trim_list('Sport') is null and app.trim_list('R-Line') is null);
insert into vehicles (id, owner_id, year, make, model, trim, vin, plate, class, status, management_mode, onboarding_method, body_type)
values (test.id('vehicle:cfbeetle'), test.id('owner:cf_owner'), 2019, 'Volkswagen', 'Beetle', 'S, Final Edition SE, Final Edition SEL, SE', '3VW5DAAT0KM500001', 'CFB001', 'standard', 'ready_to_list', 'managed', 'transfer', 'Convertible/Cabriolet');
select test.ok('stored: no trim, the candidates kept', (select trim is null and trim_candidates = array['S', 'Final Edition SE', 'Final Edition SEL', 'SE'] from vehicles where id = test.id('vehicle:cfbeetle')));
select test.ok('the name has no list', app.vehicle_name(test.id('vehicle:cfbeetle')) !~ ',');
select test.ok('Today: Pick the trim, with the candidates',
  test.cf_prompt('trim:' || test.id('vehicle:cfbeetle')) ->> 'title' like 'Pick the trim for % 2019 Volkswagen Beetle'
  and jsonb_array_length(test.cf_prompt('trim:' || test.id('vehicle:cfbeetle')) -> 'candidates') = 4);
select test.throws('pick: only an Admin', $$select app.door(test.id('cf_cs'), '', 'ops_do', 'vehicle_pick_trim', jsonb_build_object('vehicle_id', test.id('vehicle:cfbeetle'), 'trim', 'SE'))$$, 'Admin');
select test.throws('pick: one trim, not a list', $$select app.door(test.id('cf_admin'), '', 'ops_do', 'vehicle_pick_trim', jsonb_build_object('vehicle_id', test.id('vehicle:cfbeetle'), 'trim', 'S, SE'))$$, 'one trim');
select app.door(test.id('cf_admin'), '', 'ops_do', 'vehicle_pick_trim', jsonb_build_object('vehicle_id', test.id('vehicle:cfbeetle'), 'trim', 'Final Edition SE'));
select test.ok('picked: the trim saved as a person''s, the candidates cleared',
  (select trim = 'Final Edition SE' and trim_candidates is null and spec_sources #>> '{trim,source}' = 'person' from vehicles where id = test.id('vehicle:cfbeetle')));
select test.ok('picked: the Today line is gone', test.cf_prompt('trim:' || test.id('vehicle:cfbeetle')) is null);
select test.ok('picked: in the audit log', exists (select 1 from audit_log where action = 'vehicle_pick_trim' and entity_id = test.id('vehicle:cfbeetle')::text));

-- ---------------------------------------------------------------- 2. the decode: trims, gearbox and seats
insert into vehicles (id, owner_id, year, make, model, vin, plate, class, status, management_mode, onboarding_method)
values (test.id('vehicle:cfforte'), test.id('owner:cf_owner'), 2021, 'Kia', 'Forte', '3KPF24AD0ME000001', 'CFF001', 'standard', 'ready_to_list', 'managed', 'transfer'),
       (test.id('vehicle:cfjetta'), test.id('owner:cf_owner'), 2021, 'Volkswagen', 'Jetta', '3VWC57BU0MM000001', 'CFJ001', 'standard', 'ready_to_list', 'managed', 'transfer');
-- an older vPIC decode: the trims as a list in raw, Manual filled in by default, no seats
insert into vin_decodes (vin, provider, ok, raw, year, make, model, trim, body_class, transmission, doors)
values ('3KPF24AD0ME000001', 'vpic', true, '{"Trim": "FE, LXS", "TransmissionStyle": "Manual/Standard"}', 2021, 'Kia', 'Forte', null, 'Sedan/Saloon', 'Manual/Standard', 4),
-- a decode from 0094 on: the gearbox chosen from EPA's data
       ('3VWC57BU0MM000001', 'vpic', true, '{"Trim": "S / SE / R-Line", "_transmission_source": "epa"}', 2021, 'Volkswagen', 'Jetta', null, 'Sedan/Saloon', 'Automatic', 4);
select app.vin_fill_missing(test.id('vehicle:cfforte'));
select app.vin_fill_missing(test.id('vehicle:cfjetta'));
select test.ok('decode: the trims of a list kept to choose from', (select trim is null and trim_candidates = array['FE', 'LXS'] from vehicles where id = test.id('vehicle:cfforte')));
select test.ok('decode: an older vPIC gearbox is never stored', (select transmission is null from vehicle_listings where vehicle_id = test.id('vehicle:cfforte')));
select test.eq('decode: the gearbox EPA settles is stored', (select transmission from vehicle_listings where vehicle_id = test.id('vehicle:cfjetta')), 'Automatic');
select test.ok('decode: no seats from the decoder, the usual number for the body, marked to confirm',
  (select seats = 5 and spec_sources #>> '{seats,source}' = 'body_default' from vehicle_listings where vehicle_id = test.id('vehicle:cfforte')));
select test.eq('the usual seats: coupe and convertible 4, sedan, SUV and hatchback 5', array[app.body_default_seats('Convertible/Cabriolet'), app.body_default_seats('Coupe'),
  app.body_default_seats('Sedan/Saloon'), app.body_default_seats('Sport Utility Vehicle (SUV)/Multi-Purpose Vehicle (MPV)'), app.body_default_seats('Hatchback/Liftback/Notchback')], array[4, 4, 5, 5, 5]);
select test.ok('the add-a-car form gets the trims to choose from, and no older vPIC gearbox',
  (select app.vin_decode_json(d) -> 'trim_candidates' = '["FE", "LXS"]'::jsonb and app.vin_decode_json(d) ->> 'transmission' is null from vin_decodes d where d.vin = '3KPF24AD0ME000001'));
select test.ok('Today: Confirm gearbox and seats for the car without them',
  test.cf_prompt('specs:' || test.id('vehicle:cfforte')) ->> 'title' like 'Confirm gearbox and seats for %Kia Forte'
  and (test.cf_prompt('specs:' || test.id('vehicle:cfforte')) ->> 'seats_default')::boolean);
select test.throws('confirm: one of the four gearboxes', $$select app.door(test.id('cf_admin'), '', 'ops_do', 'vehicle_confirm_specs', jsonb_build_object('vehicle_id', test.id('vehicle:cfforte'), 'transmission', 'Tiptronic', 'seats', 5))$$, 'gearbox');
select app.door(test.id('cf_admin'), '', 'ops_do', 'vehicle_confirm_specs', jsonb_build_object('vehicle_id', test.id('vehicle:cfforte'), 'transmission', 'Automatic (CVT)', 'seats', 5));
select test.ok('confirmed: a person''s gearbox and seats, the line gone',
  (select transmission = 'Automatic (CVT)' and seats = 5 and spec_sources #>> '{transmission,source}' = 'person' and spec_sources #>> '{seats,source}' = 'person'
     from vehicle_listings where vehicle_id = test.id('vehicle:cfforte')) and test.cf_prompt('specs:' || test.id('vehicle:cfforte')) is null);
select app.vin_fill_missing(test.id('vehicle:cfforte'));
select test.eq('confirmed: the decoder never changes them again', (select transmission from vehicle_listings where vehicle_id = test.id('vehicle:cfforte')), 'Automatic (CVT)');

-- ---------------------------------------------------------------- 3. the games: sooner again after a close
select test.eq('games: the re-show settings the browser reads (0100, the owner''s defaults: 3rd page view or 2 minutes, 4 a visit, no daily cap)', (select jsonb_build_object('p', c -> 'reshow_pages', 's', c -> 'reshow_seconds', 'v', c -> 'per_visit', 'd', c -> 'per_day') from app.game_cfg() c),
  '{"p": 3, "s": 120, "v": 4, "d": 0}'::jsonb);
select test.throws('games: at most 50 a day', $$update program_settings set game_max_per_day = 51$$, 'check');
