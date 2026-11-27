-- R50 hotfix 2 (5143): an expense logged from its receipt photos: several photos per expense, stored as receipts; the car's
-- program owner pays by default (an owner deduction on the next statement, the receipt in the owner's documents, the owner
-- told), or CarmaCars pays (a company expense on the car, the receipt not shown to the owner); what the photo read is kept;
-- refused for the wrong person, without a photo, a tax above the amount, a date ahead, or an owner bill on a car with no
-- program owner. The vision model reads receipts within its allowance. Fixtures start with "ex5".
select test.suite('99 r50h2 expense receipts');
select test.mk_user('ex5_admin', 'admin');
select test.mk_user('ex5_fin', 'va', 'finance');
select test.mk_user('ex5_fleet', 'va', 'fleet');
select test.mk_user('ex5_cs', 'va', 'cs');
select test.mk_owner('ex5_otto');
select test.mk_vehicle('EX5A', 'ex5_otto');
create table test.ex5 (k text primary key, v jsonb);
create function test.ex5v(p text) returns jsonb language sql stable as $$ select v from test.ex5 where k = p $$;
-- the receipt keys the server builds: expenses/<this year>/<the uploader's id>/<uuid>.jpg, a new one for each tag
create function test.ex5p(n integer, who text, tag text) returns jsonb language sql stable as $$
  select jsonb_agg(jsonb_build_object('path', 'expenses/' || extract(year from app.today())::int || '/' || test.id(who) || '/' || md5('ex5' || tag || i)::uuid || '.jpg',
         'mime', 'image/jpeg', 'sha256', md5('p' || tag || i))) from generate_series(1, n) i $$;
create function test.ex5c(tag text) returns uuid language sql immutable as $$ select md5('ex5 entry ' || tag)::uuid $$;

select test.throws('who: customer service does not log expenses', format('select app.expense_log(%L, %L)', test.id('ex5_cs'), jsonb_build_object('client_entry_id', test.ex5c('t1'), 'amount_cents', 1000, 'category', 'maint_oil', 'photos', test.ex5p(1, 'ex5_cs', 't1'))), 'Admin, Finance or Fleet');
select test.throws('photos: at least one', format('select app.expense_log(%L, %L)', test.id('ex5_fleet'), jsonb_build_object('client_entry_id', test.ex5c('t2'), 'amount_cents', 1000, 'category', 'maint_oil', 'photos', '[]'::jsonb)), 'at least one photo');
select test.throws('photos: a key the server built', format('select app.expense_log(%L, %L)', test.id('ex5_fleet'), jsonb_build_object('client_entry_id', test.ex5c('t3'), 'amount_cents', 1000, 'category', 'maint_oil', 'photos', jsonb_build_array(jsonb_build_object('path', '../x.jpg')))), 'Unknown receipt file');
select test.throws('tax: never more than the amount', format('select app.expense_log(%L, %L)', test.id('ex5_fleet'), jsonb_build_object('client_entry_id', test.ex5c('t4'), 'amount_cents', 1000, 'hst_cents', 2000, 'category', 'maint_oil', 'photos', test.ex5p(1, 'ex5_fleet', 't4'))), 'tax is more');
select test.throws('date: not ahead', format('select app.expense_log(%L, %L)', test.id('ex5_fleet'), jsonb_build_object('client_entry_id', test.ex5c('t5'), 'amount_cents', 1000, 'category', 'maint_oil', 'expense_on', (app.today() + 3)::text, 'photos', test.ex5p(1, 'ex5_fleet', 't5'))), 'future');
select test.throws('owner: only a car with a program owner', format('select app.expense_log(%L, %L)', test.id('ex5_fleet'), jsonb_build_object('client_entry_id', test.ex5c('t6'), 'amount_cents', 1000, 'category', 'maint_oil', 'payer', 'owner', 'photos', test.ex5p(1, 'ex5_fleet', 't6'))), 'program owner');

-- an oil change on the owner's car, two photos: on the owner's statement by default
insert into test.ex5 select 'a', app.expense_log(test.id('ex5_fleet'), jsonb_build_object('client_entry_id', test.ex5c('a'), 'vehicle_id', test.id('vehicle:EX5A'), 'expense_on', app.today()::text, 'vendor', 'Quick Lube',
  'category', 'maint_oil', 'amount_cents', 8500, 'hst_cents', 1105, 'photos', test.ex5p(2, 'ex5_fleet', 'a'), 'read', jsonb_build_object('model', 'test-vision', 'total', 96.05, 'confidence', 90)));
select test.eq('owner pays: an open maintenance deduction on the car for the total with tax, the first photo as its receipt',
  (select d.kind || '/' || d.status || '/' || d.amount_cents || '/' || d.hst_cents || '/' || (d.vehicle_id = test.id('vehicle:EX5A')) || '/' || (d.receipt_document_id is not null)
     from owner_deductions d where d.id = (test.ex5v('a') ->> 'owner_deduction_id')::uuid), 'maintenance/open/9605/1105/true/true');
select test.eq('owner pays: both photos kept in order as receipts on the car and the owner, the read kept, no company expense',
  (select string_agg(ph.sort || ':' || d.kind || ':' || (d.vehicle_id = test.id('vehicle:EX5A')) || ':' || (d.owner_id = test.id('owner:ex5_otto')), ' ' order by ph.sort)
     from expense_entry_photos ph join documents d on d.id = ph.document_id where ph.entry_id = (test.ex5v('a') ->> 'id')::uuid) || '/' ||
  (select e.payer || ':' || (e.read ->> 'model') || ':' || (e.company_expense_id is null) from expense_entries e where e.id = (test.ex5v('a') ->> 'id')::uuid),
  '1:receipt:true:true 2:receipt:true:true/owner:test-vision:true');
select test.ok('owner pays: the receipt is in the owner''s portal documents',
  (select count(*) = 2 from jsonb_array_elements(app.owner_portal_documents((select user_id from owners where id = test.id('owner:ex5_otto')))) x where x ->> 'kind' = 'receipt'));
select test.eq('owner pays: the owner is told', (select count(*) from app_events e where e.code = 'owner_car_cost_added' and e.payload ->> 'owner_id' = test.id('owner:ex5_otto')::text and e.payload ->> 'cost_amount' = '$96.05'), 1::bigint);

-- review fixes: a double tap or a retry logs the expense once; only the caller's own fresh upload, never a file filed already
select test.eq('again: the same entry id from the same person returns the expense already logged; one deduction, one email',
  (select (x ->> 'id' = test.ex5v('a') ->> 'id') || '/' || (x ->> 'replayed') from app.expense_log(test.id('ex5_fleet'), jsonb_build_object('client_entry_id', test.ex5c('a'), 'vehicle_id', test.id('vehicle:EX5A'),
     'category', 'maint_oil', 'amount_cents', 8500, 'hst_cents', 1105, 'photos', test.ex5p(2, 'ex5_fleet', 'a-again'))) x) || '/' ||
  (select count(*) from expense_entries where created_by = test.id('ex5_fleet') and client_entry_id = test.ex5c('a')) || '/' ||
  (select count(*) from owner_deductions d where d.vehicle_id = test.id('vehicle:EX5A') and d.amount_cents = 9605) || '/' ||
  (select count(*) from app_events e where e.code = 'owner_car_cost_added' and e.payload ->> 'owner_id' = test.id('owner:ex5_otto')::text), 'true/true/1/1/1');
select test.throws('entry id: required', format('select app.expense_log(%L, %L)', test.id('ex5_fleet'), jsonb_build_object('amount_cents', 1000, 'category', 'maint_oil', 'photos', test.ex5p(1, 'ex5_fleet', 't7'))), 'no entry id');
select test.throws('photos: not another person''s upload', format('select app.expense_log(%L, %L)', test.id('ex5_fleet'), jsonb_build_object('client_entry_id', test.ex5c('t8'), 'amount_cents', 1000, 'category', 'maint_oil', 'photos', test.ex5p(1, 'ex5_fin', 't8'))), 'Unknown receipt file');
select test.throws('photos: not an old year''s key', format('select app.expense_log(%L, %L)', test.id('ex5_fleet'), jsonb_build_object('client_entry_id', test.ex5c('t9'), 'amount_cents', 1000, 'category', 'maint_oil',
  'photos', jsonb_build_array(jsonb_build_object('path', 'expenses/2019/' || test.id('ex5_fleet') || '/' || md5('t9')::uuid || '.jpg')))), 'Unknown receipt file');
select test.throws('photos: not a file already attached to another entry', format('select app.expense_log(%L, %L)', test.id('ex5_fleet'), jsonb_build_object('client_entry_id', test.ex5c('t10'), 'amount_cents', 1000, 'category', 'maint_oil', 'photos', test.ex5p(1, 'ex5_fleet', 'a'))), 'already filed');

-- the same car, CarmaCars pays: a company expense on the car; the owner does not see the receipt
insert into test.ex5 select 'b', app.expense_log(test.id('ex5_fin'), jsonb_build_object('client_entry_id', test.ex5c('b'), 'vehicle_id', test.id('vehicle:EX5A'), 'vendor', 'Car Spa', 'category', 'field_cleaning', 'payer', 'company',
  'amount_cents', 2500, 'hst_cents', 325, 'photos', test.ex5p(1, 'ex5_fin', 'b')));
select test.eq('company pays: a company expense on the car with its receipt, the owner on it, no deduction',
  (select x.category || '/' || x.amount_cents || '/' || x.hst_cents || '/' || (x.vehicle_id = test.id('vehicle:EX5A')) || '/' || (x.document_id is not null) || '/' || x.description
     from company_expenses x where x.id = (test.ex5v('b') ->> 'company_expense_id')::uuid), 'field_cleaning/2500/325/true/true/Car wash and cleaning supplies: Car Spa');
select test.eq('company pays: the owner''s documents do not list it; no notice to the owner',
  (select count(*) from jsonb_array_elements(app.owner_portal_documents((select user_id from owners where id = test.id('owner:ex5_otto')))) x where x ->> 'kind' = 'receipt')::text || '/' ||
  (select count(*) from app_events e where e.code = 'owner_car_cost_added' and e.entity_id = test.id('owner:ex5_otto')), '2/1');
-- no car, paid with a staff member's own money: owed back to them
insert into test.ex5 select 'c', app.expense_log(test.id('ex5_fleet'), jsonb_build_object('client_entry_id', test.ex5c('c'), 'category', 'field_parts', 'paid_with', 'own', 'amount_cents', 1999, 'photos', test.ex5p(1, 'ex5_fleet', 'c')));
select test.eq('own money: a company expense paid with the staff member''s own money', (select x.paid_with || '/' || (x.staff_user_id = test.id('ex5_fleet')) from company_expenses x where x.id = (test.ex5v('c') ->> 'company_expense_id')::uuid), 'own/true');

select test.eq('list: the last entries with their photos', (select jsonb_array_length(app.expense_entries_json(test.id('ex5_admin'))) >= 3 and
  (select jsonb_array_length(x -> 'photos') from jsonb_array_elements(app.expense_entries_json(test.id('ex5_admin'))) x where x ->> 'id' = test.ex5v('a') ->> 'id') = 2), true);
select test.ok('context: the owner''s car says its owner pays', (select (c ->> 'owner_pays')::boolean from jsonb_array_elements(app.expense_context(test.id('ex5_fleet')) -> 'cars') c where (c ->> 'id')::uuid = test.id('vehicle:EX5A')));
select test.eq('door: through ops_read expense_context', (select jsonb_typeof(app.door(test.id('ex5_fin'), 'aal2', 'ops_read', 'expense_context', '{}') -> 'categories')), 'array');

-- the vision model reads receipts, for the same people, counted in its allowance
select test.eq('vision: receipts are read by those who log expenses, a live vision feature', (select (app.ai_vision_gate(test.id('ex5_fleet'), 'receipt_read') ->> 'allowed') || '/' || app.ai_tier('receipt_read') || '/' || app.ai_kind('receipt_read')), 'true/live/vision');
select test.throws('vision: not for customer service', format('select app.ai_vision_gate(%L, %L)', test.id('ex5_cs'), 'receipt_read'), 'Admin, Finance or Fleet');
select app.ai_call_record(test.id('ex5_fleet'), jsonb_build_object('purpose', 'receipt_read', 'model', 'test-vision', 'ok', true, 'neurons', 120));
select test.ok('vision: a receipt read counts in the day''s allowance', (app.ai_vision_budget() ->> 'used')::bigint >= 120);
select test.ok('vision: the toll and plate purposes still pass through', (select (app.ai_vision_gate(test.id('ex5_admin'), 'toll_read') ->> 'allowed')::boolean));

select app.process_events(100000);
select test.eq('email: the owner''s email is built: no variable missing',
  (select count(*) filter (where o.missing_variables = '{}') || '/' || count(*) from notification_outbox o where o.code = 'owner_car_cost_added' and coalesce(o.channel, 'email') = 'email'
      and o.entity_id = test.id('owner:ex5_otto')) <> '0/0' and not exists (select 1 from notification_outbox o where o.code = 'owner_car_cost_added' and o.missing_variables <> '{}'), true);
