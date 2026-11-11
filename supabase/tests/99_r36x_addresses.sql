-- 99: release 36 helper X (migration 2120): the Canadian address database of the address fields: the search key, the
-- prefix search through its index, one address in its parts, the import's province replacement, and who may call them.
select test.suite('99 r36x addresses');

select test.eq('the key: lower case, accents folded, street type and direction shortened',
  app.addr_norm('65 Front Street West, Toronto'), '65 front st w toronto');
select test.eq('the key: French accents and punctuation', app.addr_norm('12, Rue de l''Église'), '12 rue de l eglise');

insert into ca_addresses (province, num, street, unit, city, postal, lat, lng) values
  ('ON', '65', 'Front St W', null, 'Toronto', 'M5J 1E6', 43.6426, -79.3871),
  ('ON', '65', 'Front St W', '4', 'Toronto', 'M5J 1E6', 43.6426, -79.3871),
  ('ON', '650', 'Frontenac Rd', null, 'Kingston', null, 44.2, -76.5),
  ('QC', '12', 'Rue de la Gare', null, 'Montréal', null, 45.5, -73.6);

select test.eq('a prefix finds the addresses that start with it, in key order',
  (select string_agg(x ->> 'label', ' | ' order by o) from jsonb_array_elements(public.server_address_search('65 front street', 6)) with ordinality t(x, o)),
  '65 Front St W, Toronto, ON M5J 1E6 | 65 Front St W, Unit 4, Toronto, ON M5J 1E6');
select test.eq('"65 front" also finds 650 Frontenac? no: the number is a whole word only when a space follows',
  jsonb_array_length(public.server_address_search('65 front', 6)), 2);
select test.eq('650 fr: Frontenac', public.server_address_search('650 fr', 6) -> 0 ->> 'label', '650 Frontenac Rd, Kingston, ON');
select test.eq('accents typed or not', jsonb_array_length(public.server_address_search('12 rue de la gare montreal', 6)), 1);
select test.eq('no number first, or too short: nothing (the fallback answers)', public.server_address_search('front st', 6) || public.server_address_search('65', 6), '[]'::jsonb);
select test.eq('the limit is at most 10', jsonb_array_length(public.server_address_search('6', 50)), 0);

select test.eq('one address in its parts',
  (select x -> 'parts' from (select public.server_address_get(public.server_address_search('65 front st w toronto', 1) -> 0 ->> 'id') x) y),
  jsonb_build_object('street', '65 Front St W', 'unit', '', 'city', 'Toronto', 'province', 'ON', 'postal_code', 'M5J 1E6', 'country', 'Canada'));
select test.ok('not one of ours: nothing', public.server_address_get('ChIJ1') is null and public.server_address_get('ca-x') is null);
select test.throws('a postal code that is not one is refused', $$insert into ca_addresses (province, street, postal) values ('ON', 'X St', 'M5J1E6')$$);

-- the import: a province's older rows go once the new ones are in; other provinces stay
create temp table ax_mark as select public.server_address_province_mark('ON') m;
insert into ca_addresses (province, num, street, city) values ('ON', '1', 'Yonge St', 'Toronto');
select test.eq('the older Ontario rows are deleted in a range', public.server_address_prune('ON', 1, (select m from ax_mark)), 3);
select test.eq('the new Ontario row and Quebec stay', (select string_agg(province || ':' || street, ',' order by province) from ca_addresses), 'ON:Yonge St,QC:Rue de la Gare');
select test.ok('the run is recorded', (public.server_address_import_begin(array['ON'], null) ->> 'id') is not null);

select test.ok('the search is the server''s only (no anon, no signed-in person)',
  not has_function_privilege('anon', 'public.server_address_search(text, integer)', 'execute')
  and not has_function_privilege('authenticated', 'public.server_address_get(text)', 'execute')
  and not has_function_privilege('authenticated', 'public.server_address_prune(text, bigint, bigint)', 'execute'));
select test.ok('the table is not readable by the public', not has_table_privilege('anon', 'ca_addresses', 'select') and not has_table_privilege('authenticated', 'ca_addresses', 'select'));
