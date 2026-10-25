-- 99: a prize already won and not claimed can be claimed from the saved badge even after the visitor became known by
-- email or started a booking request (migration 0170); those two rules still stop a NEW game. Fixtures start with "gs".
select test.suite('99 game saved claim');

create or replace function test.gsvid(p text) returns uuid language sql immutable as $$ select md5('gsvid:' || p)::uuid $$;
create or replace function test.gsstart(p text) returns jsonb language sql as $$
  select public.game_start(jsonb_build_object('vid', test.gsvid(p), 'device', 'phone', 'path', '/cars/gs-car', 'trigger', 'pages', 'seen', '[]'::jsonb)) $$;
delete from app.rate_limit_hits where key like 'game-%';
create temp table gs (n text primary key, v jsonb);
grant all on gs to public;

-- won, then typed an email somewhere on the site (known)
insert into gs values ('k', test.gsstart('known'));
select public.game_reveal((select v ->> 'token' from gs where n = 'k'));
insert into visitor_sessions (id, visitor_id, known_email) values (gen_random_uuid(), test.gsvid('known'), 'gs.known@example.test');
select test.eq('known by email after the win: the saved prize comes back',
  (select (r ->> 'ok') || ' ' || (r ->> 'saved') || ' ' || ((r ->> 'token') = (select v ->> 'token' from gs where n = 'k')) from (select test.gsstart('known') r) x), 'true true true');
select test.eq('and it is claimed',
  app.server_game_claim(jsonb_build_object('token', (select v ->> 'token' from gs where n = 'k'), 'first_name', 'Gus', 'email', 'gs.known@example.test')) ->> 'ok', 'true');
select test.eq('after the claim: never again', test.gsstart('known') ->> 'reason', 'claimed');

-- won, then started a booking request
insert into gs values ('b', test.gsstart('busy'));
select public.game_reveal((select v ->> 'token' from gs where n = 'b'));
insert into contact_captures (visitor_id, form, ref, email, page) values (test.gsvid('busy'), 'booking_request', 'gs-draft', 'gs.busy@example.test', '/book/gs-car');
select test.eq('a booking request after the win: the saved prize comes back', test.gsstart('busy') ->> 'saved', 'true');

-- known with no prize won: still no game
insert into visitor_sessions (id, visitor_id, known_email) values (gen_random_uuid(), test.gsvid('new'), 'gs.new@example.test');
select test.eq('known and nothing won: no new game', test.gsstart('new') ->> 'reason', 'known');
insert into contact_captures (visitor_id, form, ref, email, page) values (test.gsvid('req'), 'booking_request', 'gs-draft2', 'gs.req@example.test', '/book/gs-car');
select test.eq('a request in progress and nothing won: no new game', test.gsstart('req') ->> 'reason', 'in_progress');

-- won but not revealed (closed before the reveal), then known: no game (the prize was never shown)
insert into gs values ('u', test.gsstart('unrev'));
insert into visitor_sessions (id, visitor_id, known_email) values (gen_random_uuid(), test.gsvid('unrev'), 'gs.unrev@example.test');
select test.eq('known, the prize never shown: no game', test.gsstart('unrev') ->> 'reason', 'known');

select test.eq('privileges: the core stays for the service role only',
  has_function_privilege('anon', 'app.game_start_core(jsonb, uuid)', 'execute')::text || ' ' || has_function_privilege('service_role', 'app.game_start_core(jsonb, uuid)', 'execute')::text, 'false true');
