-- 99: what a person is to us (migration 0470): owner, partner, investor, staff, renter, taken from every record. An owner
-- whose browser is linked to a renters row is an owner, not a renter; an owner who has rented is both; an owner-program
-- lead is an owner; a renters row alone is a renter. The Live visitors, Live map and captured contacts reads carry roles
-- and owner_id. Fixtures start with "pr"; every address is example.test.
select test.suite('99 person roles');

select test.mk_user('pr_admin', 'admin');
select test.mk_owner('pr_olga');
select test.mk_owner('pr_ora');
select test.mk_vehicle('pr_car', 'pr_ora');
select test.mk_renter('pr_rita');
select test.mk_renter('pr_olga', false);
select test.mk_renter('pr_ora', false);
select test.mk_user('pr_staff', 'admin');
select test.mk_renter('pr_staff', false);
select test.mk_user('pr_ivy', 'renter');
insert into investors (id, user_id, legal_name, investor_type, email) values (test.id('inv:pr_ivy'), test.id('pr_ivy'), 'Pr Ivy', 'individual', 'pr_ivy@example.test');
-- olga and ora signed in on the renter side, so each has a renters row on their own login; ora has also rented
update renters set user_id = test.id('pr_olga') where id = test.id('renter:pr_olga');
update renters set user_id = test.id('pr_ora') where id = test.id('renter:pr_ora');
update renters set user_id = test.id('pr_staff') where id = test.id('renter:pr_staff');
-- numbers of their own: an earlier file may give an owner the helpers' shared renter mobile (16, 46), and a match by
-- phone would make these two owners too
update renters set mobile = '647-555-0171' where id = test.id('renter:pr_rita');
update renters set mobile = '647-555-0172' where id = test.id('renter:pr_staff');
create or replace function test.prt(p interval) returns text language sql stable as $$
  select to_char((now() + p) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:00') $$;
select test.mk_booking('PR-1', 'pr_car', 'pr_ora', test.prt('-20 days'), test.prt('-17 days'), 'closed');
select test.mk_booking('PR-2', 'pr_car', 'pr_rita', test.prt('-2 days'), test.prt('3 days'), 'on_rent');

create or replace function test.prroles(p_user uuid, p_renter uuid, p_email text default null, p_phone text default null) returns text
language sql stable as $$ select array_to_string(array(select jsonb_array_elements_text(app.person_tags(p_user, p_renter, p_email, p_phone) -> 'roles')), ' ') $$;

-- ================================================================ 1. the function
select test.eq('an owner with a renters row on the same login and no rental is an owner only', test.prroles(test.id('pr_olga'), test.id('renter:pr_olga')), 'owner');
select test.eq('the owner is found by the renter id alone (the user comes from the renters row)', test.prroles(null, test.id('renter:pr_olga')), 'owner');
select test.eq('the owner id comes with it', (app.person_tags(null, test.id('renter:pr_olga'), null, null) ->> 'owner_id')::uuid, test.id('owner:pr_olga'));
select test.eq('an owner who has rented is both, owner first', test.prroles(test.id('pr_ora'), test.id('renter:pr_ora')), 'owner renter');
select test.eq('a renter who rents is a renter only', test.prroles(test.id('pr_rita'), test.id('renter:pr_rita')), 'renter');
select test.ok('a renter has no owner id', app.person_tags(null, test.id('renter:pr_rita'), null, null) -> 'owner_id' = 'null'::jsonb);
select test.eq('an owner is found by email alone (a form typed on the site)', test.prroles(null, null, 'PR_Olga@example.test'), 'owner');
select test.eq('an owner is found by phone alone', test.prroles(null, null, null, '(416) 555-0100') like 'owner%', true);
select test.eq('a stranger has no role', test.prroles(null, null, 'pr.nobody@example.test'), '');
insert into leads (id, kind, name, email, created_at) values (test.id('lead:pr_owner'), 'owner_program', 'Pr Leadowner', 'pr.leadowner@example.test', now());
select test.eq('an owner-program lead with no owners row yet is an owner', test.prroles(null, null, 'pr.leadowner@example.test'), 'owner');
select test.eq('a staff member with a renters row is staff', test.prroles(test.id('pr_staff'), test.id('renter:pr_staff')), 'staff');
select test.eq('an investor is an investor', test.prroles(test.id('pr_ivy'), null), 'investor');
select test.eq('an investor with a renters row only is not a renter', test.prroles(null, null, 'pr_ivy@example.test'), 'investor');

-- ================================================================ 2. the reads
create or replace function test.prsid(p text) returns uuid language sql immutable as $$ select md5('pr-sid:' || p)::uuid $$;
create or replace function test.prvid(p text) returns uuid language sql immutable as $$ select md5('pr-vid:' || p)::uuid $$;
insert into visitor_sessions (id, visitor_id, user_id, renter_id, known_name, consent, city, last_seen_at, started_at, page_views)
values (test.prsid('olga'), test.prvid('olga'), test.id('pr_olga'), test.id('renter:pr_olga'), 'Pr Olga', 'analytics', 'Toronto', now(), now() - interval '5 minutes', 3),
       (test.prsid('rita'), test.prvid('rita'), test.id('pr_rita'), test.id('renter:pr_rita'), 'Pr Rita', 'analytics', 'Toronto', now(), now() - interval '5 minutes', 3),
       (test.prsid('ora'), test.prvid('ora'), test.id('pr_ora'), test.id('renter:pr_ora'), 'Pr Ora', 'analytics', 'Toronto', now(), now() - interval '5 minutes', 3);
select test.eq('Live visitors: the owner''s visit says owner, with the owner id',
  (select format('%s %s', array_to_string(array(select jsonb_array_elements_text(x -> 'roles')), ' '), (x ->> 'owner_id')::uuid = test.id('owner:pr_olga'))
     from jsonb_array_elements(app.live_visitors(test.id('pr_admin')) -> 'now') x where x ->> 'id' = test.prsid('olga')::text),
  'owner t');
select test.eq('Live visitors: the renter''s visit says renter',
  (select array_to_string(array(select jsonb_array_elements_text(x -> 'roles')), ' ') from jsonb_array_elements(app.live_visitors(test.id('pr_admin')) -> 'now') x where x ->> 'id' = test.prsid('rita')::text),
  'renter');
select test.eq('Live visitors: an owner who rents says both',
  (select array_to_string(array(select jsonb_array_elements_text(x -> 'roles')), ' ') from jsonb_array_elements(app.live_visitors(test.id('pr_admin')) -> 'now') x where x ->> 'id' = test.prsid('ora')::text),
  'owner renter');
create temp table s99pr as select app.door(test.id('pr_admin'), 'aal2', 'admin_read', 'live_map', jsonb_build_object('who', jsonb_build_array(
  test.id('renter:pr_olga'), test.id('renter:pr_rita'), test.id('renter:pr_ora')))) as v;
create or replace function test.prpin(p_renter text) returns text language sql stable as $$
  select array_to_string(array(select jsonb_array_elements_text(x -> 'roles')), ' ') from jsonb_array_elements((select v from pg_temp.s99pr) -> 'pins') x
   where x ->> 'renter_id' = test.id('renter:' || p_renter)::text $$;
select test.eq('Live map: the owner''s pin says owner', test.prpin('pr_olga'), 'owner');
select test.eq('Live map: the renter on rent says renter', test.prpin('pr_rita'), 'renter');
select test.eq('Live map: the owner who rents says both', test.prpin('pr_ora'), 'owner renter');
select test.eq('Live map: the renter is still on rent (the roles change no pin type)',
  (select x ->> 'type' from jsonb_array_elements((select v from pg_temp.s99pr) -> 'pins') x where x ->> 'renter_id' = test.id('renter:pr_rita')::text), 'on_rent');
insert into contact_captures (visitor_id, form, ref, name, email, lead_id, done_at, done_reason)
values (test.prvid('lead'), 'owner_lead', 'pr-lead', 'Pr Leadowner', 'pr.leadowner@example.test', test.id('lead:pr_owner'), now(), 'sent');
select test.eq('Renter leads page: a captured owner form says owner',
  (select array_to_string(array(select jsonb_array_elements_text(x -> 'roles')), ' ') from jsonb_array_elements(app.captured_contacts(test.id('pr_admin'), '{"q": "Leadowner"}') -> 'rows') x limit 1), 'owner');

-- ================================================================ 3. Visitor history rows carry the role, score, cars, trail and chat
update visitor_sessions set score = 55, cars_viewed = array[test.id('vehicle:pr_car')] where id = test.prsid('ora');
insert into visitor_events (session_id, kind, path) values (test.prsid('ora'), 'page_view', '/cars'), (test.prsid('ora'), 'page_view', '/list-your-car');
select test.eq('Visitor history: the owner who rents says both, with score, one car, a two-page trail and no chat',
  (select format('%s %s %s %s %s %s', array_to_string(array(select jsonb_array_elements_text(x -> 'roles')), ' '), x ->> 'score', x ->> 'cars_n',
            jsonb_array_length(x -> 'cars'), jsonb_array_length(x -> 'trail'), x ->> 'chat')
     from (select app.visit_history_extra(s) as x from visitor_sessions s where s.id = test.prsid('ora')) y),
  'owner renter 55 1 1 2 false');
select test.ok('Visitor history: every row of the read carries roles and a trail',
  (select bool_and(x ? 'roles' and x ? 'trail') and count(*) > 0 from jsonb_array_elements(app.visitor_history(test.id('pr_admin'), '{"bots": "1", "summary": "0", "limit": 5}') -> 'rows') x));
