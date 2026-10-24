-- 84: which credit cards include rental car coverage (migration 0131, docs/changes/2026-10-24-credit-card-coverage.md).
-- The list seeded from the research of October 23, 2026, the site's read (active cards only, anonymous visitors too),
-- Admin's read and save through the door (Admins only; facts changed without a date are checked today), and Admin > Today
-- for a card not checked in 6 months. Fixtures start with "cc31".
select test.suite('84 card coverage');
select test.mk_user('cc31_admin', 'admin');
select test.mk_user('cc31_cs', 'va', 'cs');

-- ---------------------------------------------------------------- 1. the seeded list
select test.ok('seeded: at least 40 cards, Canadian and US',
  (select count(*) >= 40 and count(*) filter (where country = 'US') >= 5 from card_rental_coverage));
select test.eq('seeded: the issuers the renters ask about',
  (select count(distinct issuer) from card_rental_coverage where issuer in ('American Express', 'RBC', 'TD', 'CIBC', 'Scotiabank', 'BMO', 'National Bank', 'Desjardins',
     'HSBC', 'Tangerine', 'Simplii Financial', 'PC Financial', 'Rogers Bank', 'Brim', 'Neo Financial', 'Chase', 'Capital One', 'American Express (US)', 'Citi')), 19::bigint);
select test.eq('seeded: every card checked on October 23, 2026', (select count(*) from card_rental_coverage where last_checked <> '2026-10-23'), 0::bigint);
select test.eq('seeded: a card read in the issuer''s document links to it', (select count(*) from card_rental_coverage where issuer_checked and guide_url is null), 0::bigint);
select test.eq('seeded: an unverified card says where its numbers came from', (select count(*) from card_rental_coverage where not issuer_checked and source_url is null and note is null), 0::bigint);
select test.eq('seeded: the value limits (Cobalt $85,000, eclipse Visa Infinite $65,000 secondary, Aventura Visa Infinite Privilege $100,000)',
  (select string_agg(card || ' ' || coalesce(max_msrp_cents / 100, 0) || ' ' || coverage, ', ' order by card) from card_rental_coverage
    where card in ('Cobalt Card', 'eclipse Visa Infinite', 'Aventura Visa Infinite Privilege')),
  'Aventura Visa Infinite Privilege 100000 ask, Cobalt Card 85000 ask, eclipse Visa Infinite 65000 secondary');
select test.eq('seeded: no dash used as punctuation in the text',
  (select count(*) from card_rental_coverage where concat_ws(' ', issuer, card, value_note, exclusions, conditions, car_sharing, note) ~ ('[' || chr(8212) || ']| ' || chr(8211) || ' ')), 0::bigint);
select test.eq('seeded: the Protection Plan''s provider and the numbered company are never named',
  (select count(*) from card_rental_coverage where concat_ws(' ', value_note, exclusions, conditions, car_sharing, note) ~* '18122211|canada inc'), 0::bigint);

-- ---------------------------------------------------------------- 2. the site's read
update card_rental_coverage set is_active = false where issuer = 'Simplii Financial';
create table test.cc31n as select count(*)::integer n from card_rental_coverage where is_active;
grant select on test.cc31n to anon;
set role anon;
select test.eq('anon: the site''s read lists the active cards, Canadian first',
  (public.card_coverage_public() #>> '{cards,0,country}') || '/' || jsonb_array_length(public.card_coverage_public() -> 'cards'), 'CA/' || (select n from test.cc31n));
select test.eq('anon: a hidden card is not listed',
  (select count(*) from jsonb_array_elements(public.card_coverage_public() -> 'cards') c where c ->> 'issuer' = 'Simplii Financial'), 0::bigint);
select test.eq('anon: the read leaves out who changed a card', (public.card_coverage_public() #> '{cards,0}') ? 'updated_by', false);
select test.eq('anon: the newest check date', public.card_coverage_public() ->> 'checked', '2026-10-23');
select test.eq('anon: no privilege on the table itself (the site reads the function)', test.visible('select * from card_rental_coverage'), -1::bigint);
select test.throws('anon: cannot change the list', $$update card_rental_coverage set max_days = 1$$, null);
select test.throws('anon: cannot reach the door', $$select app.door(null, 'aal1', 'admin_read', 'card_coverage', '{}')$$, null);
reset role;

-- ---------------------------------------------------------------- 3. Admin: read and save through the door
select test.eq('Admin: the read has every card, hidden ones too',
  jsonb_array_length(app.door(test.id('cc31_admin'), 'aal2', 'admin_read', 'card_coverage', '{}') -> 'cards'), (select count(*)::integer from card_rental_coverage));
select test.throws('customer service cannot read Admin''s list', $$select app.door(test.id('cc31_cs'), 'aal2', 'admin_read', 'card_coverage', '{}')$$, null);
select test.throws('customer service cannot change a card',
  $$select app.door(test.id('cc31_cs'), 'aal2', 'admin_save', 'card_rental_coverage', '{"values":{"issuer":"Example","card":"Test"}}')$$, null);

create table test.cc31 (k text primary key, v uuid);
insert into test.cc31 select 'new', (app.door(test.id('cc31_admin'), 'aal2', 'admin_save', 'card_rental_coverage',
  '{"key":null,"values":{"country":"CA","issuer":" Example Credit Union ","card":"Travel World Elite","coverage":"primary","max_msrp_cents":7500000,"max_days":31,"guide_url":"https://example.test/guide.pdf","value_note":"","issuer_checked":true}}') ->> 'id')::uuid;
insert into test.cc31 select 'empty', (app.door(test.id('cc31_admin'), 'aal2', 'admin_save', 'card_rental_coverage',
  '{"values":{"issuer":"Example Credit Union","card":"Empty Fields","exclusions":null,"conditions":null,"sort_order":null,"coverage":null,"last_checked":null,"max_msrp_cents":null}}') ->> 'id')::uuid;
select test.eq('Admin adds a card with the form''s empty fields: plain values, not nulls',
  (select exclusions || '/' || conditions || '/' || sort_order || '/' || coverage from card_rental_coverage where id = (select v from test.cc31 where k = 'empty')), '//0/ask');
delete from card_rental_coverage where card = 'Empty Fields';
select test.eq('Admin adds a card: trimmed, an empty note is no note, checked today, who added it',
  (select issuer || '/' || coalesce(value_note, 'null') || '/' || (last_checked = app.today()) || '/' || (updated_by = test.id('cc31_admin')) from card_rental_coverage where id = (select v from test.cc31 where k = 'new')),
  'Example Credit Union/null/true/true');
update card_rental_coverage set last_checked = '2026-01-02' where id = (select v from test.cc31 where k = 'new');
select app.door(test.id('cc31_admin'), 'aal2', 'admin_save', 'card_rental_coverage', jsonb_build_object('key', (select v from test.cc31 where k = 'new'), 'values', '{"max_msrp_cents":8500000}'::jsonb));
select test.eq('Admin changes a limit without a date: checked today',
  (select (max_msrp_cents / 100) || '/' || (last_checked = app.today()) from card_rental_coverage where id = (select v from test.cc31 where k = 'new')), '85000/true');
select app.door(test.id('cc31_admin'), 'aal2', 'admin_save', 'card_rental_coverage', jsonb_build_object('key', (select v from test.cc31 where k = 'new'), 'values', '{"max_days":48,"last_checked":"2026-09-30"}'::jsonb));
select test.eq('Admin gives the date: that date', (select max_days || '/' || last_checked from card_rental_coverage where id = (select v from test.cc31 where k = 'new')), '48/2026-09-30');
select app.door(test.id('cc31_admin'), 'aal2', 'admin_save', 'card_rental_coverage', jsonb_build_object('key', (select v from test.cc31 where k = 'new'), 'values', '{"sort_order":5}'::jsonb));
select test.eq('Admin changes only the order: the date stays', (select last_checked::text from card_rental_coverage where id = (select v from test.cc31 where k = 'new')), '2026-09-30');
select test.throws('a link must start with https://',
  format($$select app.door(test.id('cc31_admin'), 'aal2', 'admin_save', 'card_rental_coverage', '{"key":"%s","values":{"guide_url":"http://example.test"}}')$$, (select v from test.cc31 where k = 'new')), 'https://');
select test.throws('an unknown field is refused',
  format($$select app.door(test.id('cc31_admin'), 'aal2', 'admin_save', 'card_rental_coverage', '{"key":"%s","values":{"id":"x"}}')$$, (select v from test.cc31 where k = 'new')), 'Not a field');
select test.throws('the same card twice is refused',
  $$select app.door(test.id('cc31_admin'), 'aal2', 'admin_save', 'card_rental_coverage', '{"values":{"country":"CA","issuer":"Example Credit Union","card":"Travel World Elite"}}')$$, 'already on the list');
select test.throws('a coverage kind outside the list is refused',
  format($$select app.door(test.id('cc31_admin'), 'aal2', 'admin_save', 'card_rental_coverage', '{"key":"%s","values":{"coverage":"maybe"}}')$$, (select v from test.cc31 where k = 'new')), null);
select test.ok('every change is in the audit log',
  (select count(*) >= 4 from audit_log where entity_table = 'card_rental_coverage' and entity_id = (select v::text from test.cc31 where k = 'new')));

-- ---------------------------------------------------------------- 4. Admin > Today
select test.eq('Today: nothing while every card was checked in the last 6 months',
  (select count(*) from jsonb_array_elements(app.site_setup_problems()) x where x ->> 'field' = 'card_coverage'), 0::bigint);
update card_rental_coverage set last_checked = app.today() - 200 where id = (select v from test.cc31 where k = 'new');
select test.eq('Today: a card not checked for 6 months, linked to Settings > Card coverage',
  (select (x ->> 'href') || ' ' || (x ->> 'message' like '%1 card was last checked more than 6 months ago%') from jsonb_array_elements(app.site_setup_problems()) x where x ->> 'field' = 'card_coverage'),
  '/admin/settings/card-coverage true');
update card_rental_coverage set is_active = false where id = (select v from test.cc31 where k = 'new');
select test.eq('Today: a hidden card does not count',
  (select count(*) from jsonb_array_elements(app.site_setup_problems()) x where x ->> 'field' = 'card_coverage'), 0::bigint);

-- the list as it was
delete from card_rental_coverage where id = (select v from test.cc31 where k = 'new');
update card_rental_coverage set is_active = true where issuer = 'Simplii Financial';
drop table test.cc31;
drop table test.cc31n;
