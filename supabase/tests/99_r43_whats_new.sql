-- 99: migration 2730 (release 43): the "What's new" pop-up is shown once per person, release and portal. The table holds who
-- has seen what; marking is idempotent and one's own; the Admin reads all; nobody else reads another person's rows.
-- Fixtures start with "rq43w"; addresses are example.test.
select test.suite('99 r43 what''s new (2730)');

select test.mk_user('rq43w_admin', 'admin');
select test.mk_user('rq43w_ann', 'va', 'sales');
select test.mk_user('rq43w_bob', 'va', 'cs');

select test.eq('nothing seen at first', public.release_seen_list(test.id('rq43w_ann'), 'staff'), '{}'::text[]);
select test.eq('the server marks a release seen for a person', public.release_seen_mark('rq43w-r1', 'staff', test.id('rq43w_ann')), true);
select test.eq('... and again: still one row', (public.release_seen_mark('rq43w-r1', 'staff', test.id('rq43w_ann')), (select count(*) from user_release_seen where user_id = test.id('rq43w_ann')))::text, '(t,1)');
select test.eq('the list holds it', public.release_seen_list(test.id('rq43w_ann'), 'staff'), array['rq43w-r1']);
select test.eq('... per portal: not seen in another portal of the same person', public.release_seen_list(test.id('rq43w_ann'), 'owner'), '{}'::text[]);
select test.eq('... and not seen by someone else', public.release_seen_list(test.id('rq43w_bob'), 'staff'), '{}'::text[]);
select test.throws('no person, no mark', $$select public.release_seen_mark('rq43w-r1', 'staff', null)$$, 'Unknown person');
select test.throws('an unknown person is refused', $$select public.release_seen_mark('rq43w-r1', 'staff', gen_random_uuid())$$, 'Unknown person');
select test.throws('an unknown portal is refused', $$select public.release_seen_mark('rq43w-r1', 'nowhere', test.id('rq43w_ann'))$$);
select test.throws('a release id is a short plain word', $$select public.release_seen_mark('Not A Release!', 'staff', test.id('rq43w_ann'))$$);

select test.eq('only the server may call the functions',
  has_function_privilege('service_role', 'public.release_seen_mark(text, text, uuid)', 'execute')
  and has_function_privilege('service_role', 'public.release_seen_list(uuid, text)', 'execute')
  and not has_function_privilege('authenticated', 'public.release_seen_mark(text, text, uuid)', 'execute')
  and not has_function_privilege('authenticated', 'public.release_seen_list(uuid, text)', 'execute')
  and not has_function_privilege('anon', 'public.release_seen_mark(text, text, uuid)', 'execute')
  and not has_function_privilege('anon', 'public.release_seen_list(uuid, text)', 'execute'), true);
select test.eq('the table has row level security', (select relrowsecurity from pg_class where oid = 'public.user_release_seen'::regclass), true);

select public.release_seen_mark('rq43w-r2', 'staff', test.id('rq43w_bob'));
select test.login(test.id('rq43w_bob'));
select test.eq('signed in: reads only their own rows', test.visible('select 1 from user_release_seen where release like ''rq43w-%'''), 1::bigint);
select test.logout();

select test.login(test.id('rq43w_admin'));
select test.eq('an Admin reads every row', test.visible('select 1 from user_release_seen where release like ''rq43w-%'''), 2::bigint);
select test.logout();

-- the table cannot be written directly from the browser
select test.login(test.id('rq43w_bob'));
select test.throws('no direct insert', $$insert into user_release_seen (user_id, release, portal) values (auth.uid(), 'rq43w-r9', 'staff')$$);
select test.logout();

-- deleting a person takes their rows with them
select test.mk_user('rq43w_gone', 'va', 'cs');
select public.release_seen_mark('rq43w-r1', 'staff', test.id('rq43w_gone'));
delete from users where id = test.id('rq43w_gone');
select test.eq('rows go with the person', (select count(*) from user_release_seen where user_id = test.id('rq43w_gone')), 0::bigint);
