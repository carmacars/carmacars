-- 99: one model name per car family (migration 0520). The same cases as web/src/features/vin/model-family.cases.json (the
-- unit test reads that file): every make, model and trim in the seeds, the shapes VIN decode, permit scans and partner
-- sheets give, and values that must stay exactly as typed. Then the save trigger, the audit of the backfill, the slug
-- that never changes, and the Data health line. Fixtures start with "mf"; every address is example.test.
select test.suite('99 model families');

create temp table mf_cases (make text, model text, trim text, want_model text, want_trim text);
insert into mf_cases values
  ('Mercedes-Benz', 'C-Class', 'C300', 'C-Class', 'C300'),
  ('Mercedes-Benz', 'C300', null, 'C-Class', 'C300'),
  ('Mercedes-Benz', 'C300', '4MATIC', 'C-Class', 'C300 4MATIC'),
  ('Mercedes-Benz', 'C 300', 'C300 4MATIC', 'C-Class', 'C300 4MATIC'),
  ('Mercedes-Benz', 'C300 4Matic', null, 'C-Class', 'C300 4MATIC'),
  ('Mercedes-Benz', 'C-Class', 'C300 Cabriolet', 'C-Class', 'C300 Cabriolet'),
  ('Mercedes-Benz', 'C-Class', 'C43 AMG', 'C-Class', 'C43 AMG'),
  ('Mercedes-Benz', 'C-Class', 'C63 S AMG', 'C-Class', 'C63 S AMG'),
  ('Mercedes-Benz', 'CLA250', null, 'CLA-Class', 'CLA250'),
  ('Mercedes-Benz', 'CLA 250', '4MATIC', 'CLA-Class', 'CLA250 4MATIC'),
  ('Mercedes-Benz', 'CLA', 'CLA250 4MATIC', 'CLA-Class', 'CLA250 4MATIC'),
  ('Mercedes-Benz', 'CLA-Class', 'CLA250 4MATIC', 'CLA-Class', 'CLA250 4MATIC'),
  ('Mercedes-Benz', 'A-Class', 'A220', 'A-Class', 'A220'),
  ('Mercedes-Benz', 'A-Class', 'A35 AMG', 'A-Class', 'A35 AMG'),
  ('Mercedes-Benz', 'A220', '4MATIC', 'A-Class', 'A220 4MATIC'),
  ('Mercedes-Benz', 'GLA250', null, 'GLA-Class', 'GLA250'),
  ('Mercedes-Benz', 'GLA-Class', 'GLA250 4MATIC', 'GLA-Class', 'GLA250 4MATIC'),
  ('Mercedes-Benz', 'GLB', 'GLB250', 'GLB', 'GLB250'),
  ('Mercedes-Benz', 'GLB', 'GLB35 AMG', 'GLB', 'GLB35 AMG'),
  ('Mercedes-Benz', 'GLC', 'GLC43 AMG', 'GLC', 'GLC43 AMG'),
  ('Mercedes-Benz', 'GLC', 'GLC43 AMG Coupe', 'GLC', 'GLC43 AMG Coupe'),
  ('Mercedes-Benz', 'GLC-Class', 'GLC300 4MATIC', 'GLC', 'GLC300 4MATIC'),
  ('Mercedes-Benz', 'GLC300', null, 'GLC', 'GLC300'),
  ('Mercedes-Benz', 'GLE', 'GLE53 AMG', 'GLE', 'GLE53 AMG'),
  ('Mercedes-Benz', 'GLE', 'GLE53 AMG Coupe', 'GLE', 'GLE53 AMG Coupe'),
  ('Mercedes-Benz', 'GLE 450', '4MATIC', 'GLE', 'GLE450 4MATIC'),
  ('Mercedes-Benz', 'GLS', 'Maybach GLS600', 'GLS', 'Maybach GLS600'),
  ('Mercedes-Benz', 'S-Class', 'Maybach S580', 'S-Class', 'Maybach S580'),
  ('Mercedes-Benz', 'S-Class', 'S500', 'S-Class', 'S500'),
  ('Mercedes-Benz', 'S-Class', 'S580', 'S-Class', 'S580'),
  ('Mercedes-Benz', 'S-Class', 'S63 AMG', 'S-Class', 'S63 AMG'),
  ('Mercedes-Benz', 'S580', '4MATIC', 'S-Class', 'S580 4MATIC'),
  ('Mercedes-Benz', 'E-Class', 'E43 AMG', 'E-Class', 'E43 AMG'),
  ('Mercedes-Benz', 'E-Class', 'E53 AMG Coupe', 'E-Class', 'E53 AMG Coupe'),
  ('Mercedes-Benz', 'G-Class', 'G63 AMG', 'G-Class', 'G63 AMG'),
  ('Mercedes-Benz', 'G63 AMG', null, 'G-Class', 'G63 AMG'),
  ('Mercedes-Benz', 'AMG GT', 'GT53 4-Door Coupe', 'AMG GT', 'GT53 4-Door Coupe'),
  ('Mercedes-Benz', 'AMG GT 53', null, 'AMG GT', 'GT53'),
  ('Mercedes-Benz', 'C 300 X1', null, 'C 300 X1', null),
  ('Mercedes-Benz', 'C 300 E', null, 'C 300 E', null),
  ('Mercedes-Benz', 'C 300 S', null, 'C 300 S', null),
  ('BMW', '3 Series', '330i M Sport', '3 Series', '330i M Sport'),
  ('BMW', '3 Series', 'M340i', '3 Series', 'M340i'),
  ('BMW', '330i', null, '3 Series', '330i'),
  ('BMW', '330i xDrive', null, '3 Series', '330i xDrive'),
  ('BMW', 'M440i', 'Gran Coupe', '4 Series', 'M440i Gran Coupe'),
  ('BMW', '4 Series', 'M440i Gran Coupe', '4 Series', 'M440i Gran Coupe'),
  ('BMW', '5 Series', '530i M Sport', '5 Series', '530i M Sport'),
  ('BMW', 'M3', 'Competition', 'M3', 'Competition'),
  ('BMW', 'M4', 'Competition', 'M4', 'Competition'),
  ('BMW', 'X3', null, 'X3', null),
  ('BMW', 'X3 M', 'Competition', 'X3 M', 'Competition'),
  ('BMW', 'X4', 'M40i', 'X4', 'M40i'),
  ('BMW', 'X5', 'M Sport', 'X5', 'M Sport'),
  ('BMW', 'X5 xDrive40i', null, 'X5', 'xDrive40i'),
  ('BMW', 'X6 M', null, 'X6 M', null),
  ('Audi', 'A5', 'Cabriolet', 'A5', 'Cabriolet'),
  ('Audi', 'R8', 'Spyder', 'R8', 'Spyder'),
  ('Porsche', '911', 'Turbo S', '911', 'Turbo S'),
  ('Porsche', '718 Boxster', null, '718 Boxster', null),
  ('Land Rover', 'Range Rover Sport', 'V8', 'Range Rover Sport', 'V8'),
  ('Cadillac', 'Escalade', 'ESV', 'Escalade', 'ESV'),
  ('Ferrari', '488', 'Spider', '488', 'Spider'),
  ('Honda', 'Civic', 'EX', 'Civic', 'EX');
select test.eq(format('%s %s / %s is %s / %s', make, model, coalesce(trim, '-'), want_model, coalesce(want_trim, '-')),
  (select format('%s / %s', f ->> 'model', coalesce(f ->> 'trim', '-')) from (select app.car_model_family(make, model, trim) f) z),
  format('%s / %s', want_model, coalesce(want_trim, '-')))
  from mf_cases;
select test.eq('applying it twice changes nothing',
  (select count(*) from mf_cases c, lateral (select app.car_model_family(c.make, c.model, c.trim) a) x,
          lateral (select app.car_model_family(c.make, x.a ->> 'model', x.a ->> 'trim') b) y
    where (x.a ->> 'model', x.a ->> 'trim') is distinct from (y.b ->> 'model', y.b ->> 'trim')), 0::bigint);
select test.eq('every car the migrations put on file is already one family per model (the backfill ran)',
  (select count(*) from vehicles v where (app.car_model_family(v.make, v.model, v.trim) ->> 'model') is distinct from v.model), 0::bigint);

-- ================================================================ the save: any path that writes vehicles
select test.mk_user('mf_admin', 'admin');
select test.mk_owner('mf_olive');
select test.mk_vehicle('mf_car', 'mf_olive');
update vehicles set model = 'C300', trim = '4MATIC' where id = test.id('vehicle:mf_car');
select test.eq('a car saved as C300 / 4MATIC (a permit or a sheet) is the C-Class, trim C300 4MATIC',
  (select model || ' / ' || trim from vehicles where id = test.id('vehicle:mf_car')), 'C-Class / C300 4MATIC');
update vehicles set make = 'MERCEDES-BENZ', model = 'CLA250', trim = null where id = test.id('vehicle:mf_car');
select test.eq('in capitals from a VIN decode: proper case first (0087), then the family',
  (select make || ' ' || model || ' / ' || trim from vehicles where id = test.id('vehicle:mf_car')), 'Mercedes-Benz CLA-Class / CLA250');
insert into vehicle_listings (vehicle_id, status, slug) values (test.id('vehicle:mf_car'), 'draft', 'mf-2023-mercedes-benz-cla250')
on conflict (vehicle_id) do update set slug = excluded.slug;
update vehicles set model = 'CLA 250', trim = '4MATIC' where id = test.id('vehicle:mf_car');
select test.eq('the listing''s public address never changes with the name',
  (select slug from vehicle_listings where vehicle_id = test.id('vehicle:mf_car')), 'mf-2023-mercedes-benz-cla250');

-- ================================================================ the backfill, audited
alter table vehicles disable trigger vehicles_a1_model_family;
update vehicles set model = 'GLA250', trim = '4MATIC' where id = test.id('vehicle:mf_car');
alter table vehicles enable trigger vehicles_a1_model_family;
select test.eq('the backfill renames a car saved before the rule', app.car_model_family_backfill(), 1);
select test.eq('to the GLA-Class, trim GLA250 4MATIC', (select model || ' / ' || trim from vehicles where id = test.id('vehicle:mf_car')), 'GLA-Class / GLA250 4MATIC');
select test.eq('the audit log keeps the names before and after',
  (select format('%s %s -> %s %s', before ->> 'model', before ->> 'trim', after ->> 'model', after ->> 'trim') from audit_log
    where action = 'model_family' and entity_id = test.id('vehicle:mf_car')::text order by at desc, id desc limit 1),
  'GLA250 4MATIC -> GLA-Class GLA250 4MATIC');
select test.eq('run again: nothing left to rename', app.car_model_family_backfill(), 0);

-- ================================================================ Data health: a family we do not know
update vehicles set model = 'Clase Cee', trim = null where id = test.id('vehicle:mf_car');
select test.ok('Data health lists the Mercedes-Benz car whose model is not a family we know, with its link',
  exists (select 1 from jsonb_array_elements(app.data_health() -> 'checks') c, jsonb_array_elements(c -> 'items') i
           where c ->> 'key' = 'model_family' and i ->> 'id' = test.id('vehicle:mf_car')::text and i ->> 'href' = '/admin/vehicles/' || test.id('vehicle:mf_car')));
update vehicles set model = 'C-Class', trim = 'C43 AMG' where id = test.id('vehicle:mf_car');
select test.ok('a known family is not listed',
  not exists (select 1 from jsonb_array_elements(app.data_health() -> 'checks') c, jsonb_array_elements(c -> 'items') i
               where c ->> 'key' = 'model_family' and i ->> 'id' = test.id('vehicle:mf_car')::text));
select test.ok('the line counts into the total', (select (r ->> 'issues')::integer = (select sum((c ->> 'count')::integer) from jsonb_array_elements(r -> 'checks') c)
  from (select app.data_health() r) z));
