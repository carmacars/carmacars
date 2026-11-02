-- 99: the App Store and Google Play app (migration 0390): the app's devices in the same alerts outbox, sent only by a
-- Worker that has their keys, and Delete my account. Fixtures start with "na"; tokens are made-up strings.
select test.suite('99 native apps');
select test.mk_user('na_admin', 'admin');
select test.mk_renter('na_rena');
select test.mk_renter('na_ravi');

create or replace function test.na_app(p_label text, p_user uuid, p_platform text default 'ios') returns jsonb
language sql as $$ select app.push_subscribe(p_user, jsonb_build_object('kind', 'fcm', 'token', 'na-token-' || p_label || '-' || repeat('x', 40),
  'platform', p_platform, 'portal', 'renter', 'device', 'CarmaCars app on iPhone')) $$;

-- ================================================================== the app's device
create temp table na_first as select test.na_app('one', test.id('na_rena')) as st;
select test.eq('the app gives a token: one device of kind fcm, no browser keys, its platform',
  (select st -> 'devices' -> 0 ->> 'kind' from na_first)
  || '/' || (select kind || '/' || platform || '/' || (p256dh is null and auth is null) || '/' || left(endpoint, 16) from push_subscriptions where user_id = test.id('na_rena')),
  'fcm/fcm/ios/true/fcm:na-token-one');
select test.eq('the state of this device by its fcm: address', app.push_state(test.id('na_rena'), 'fcm:na-token-one-' || repeat('x', 40)) ->> 'this_device', 'true');
select test.throws('a token that is not one is refused', $$select app.push_subscribe(test.id('na_rena'), '{"kind": "fcm", "token": "bad token!"}')$$, 'cannot use');
select test.throws('an app device cannot carry browser keys', $$insert into push_subscriptions (user_id, kind, endpoint, p256dh, auth)
  values (test.id('na_rena'), 'fcm', 'fcm:' || repeat('a', 30), 'B' || repeat('A', 86), repeat('Q', 22))$$, 'push_subscriptions_shape_check');
select test.throws('a browser device still needs its keys', $$insert into push_subscriptions (user_id, kind, endpoint)
  values (test.id('na_rena'), 'web', 'https://push.example.test/na')$$, 'push_subscriptions_shape_check');
select test.eq('a browser device still subscribes as before (kind web)',
  (app.push_subscribe(test.id('na_rena'), jsonb_build_object('endpoint', 'https://push.example.test/send/na-web', 'p256dh', 'B' || repeat('A', 86), 'auth', repeat('Q', 22))) -> 'devices' -> 0 ->> 'kind'), 'web');
select test.na_app('one', test.id('na_ravi'), 'android');
select test.eq('one phone, one person: the app signed in as someone else alerts that person, with the new platform',
  (select user_id = test.id('na_ravi') and platform = 'android' from push_subscriptions where endpoint like 'fcm:na-token-one-%'), true);
select test.na_app('one', test.id('na_rena'));

-- ================================================================== the outbox by kind
insert into notifications (id, user_id, code, title, body, url, dedupe_key)
  values (test.id('na_n1'), test.id('na_rena'), 'renter_late_return_first', 'Your car is due back', 'Return it now', '/account', 'na:n1');
select test.eq('the notice queued an alert for both devices', (select string_agg(s.kind, ',' order by s.kind) from push_outbox o join push_subscriptions s on s.id = o.subscription_id
  where o.notification_id = test.id('na_n1')), 'fcm,web');
select test.ok('a Worker with only the browser keys has nothing to send for the app (and the browser alert waits)',
  app.server_push_waiting(array['web']) and app.server_push_waiting(array['fcm']) and app.server_push_waiting());
create temp table na_web as select d.value as d from jsonb_array_elements(app.server_push_due(200, array['web'])) d;
select test.eq('claimed with the browser keys only: the browser alert, never the app''s',
  (select string_agg(d ->> 'kind', ',') from na_web where d -> 'payload' ->> 'code' = 'renter_late_return_first'), 'web');
select test.eq('the app''s alert is still queued', (select o.status from push_outbox o join push_subscriptions s on s.id = o.subscription_id
  where o.notification_id = test.id('na_n1') and s.kind = 'fcm'), 'queued');
create temp table na_fcm as select d.value as d from jsonb_array_elements(app.server_push_due(200, array['fcm'])) d;
select test.eq('claimed with the Firebase account: the token without its prefix, the platform, urgent, the payload',
  (select (d ->> 'token' like 'na-token-one-%') || '/' || (d ->> 'endpoint' is null) || '/' || (d ->> 'platform') || '/' || (d ->> 'urgent') || '/' || (d -> 'payload' ->> 'url')
     from na_fcm where d -> 'payload' ->> 'code' = 'renter_late_return_first'), 'true/true/ios/true//account');
select test.eq('the answers apply to app devices as to browsers',
  (app.server_push_result(jsonb_build_object('results', jsonb_build_array(
     jsonb_build_object('id', (select d ->> 'id' from na_fcm where d -> 'payload' ->> 'code' = 'renter_late_return_first'), 'outcome', 'gone')))))::text,
  '{"gone": 1, "sent": 0, "retry": 0, "failed": 0}');
select test.eq('gone deletes the app device', (select count(*) from push_subscriptions where user_id = test.id('na_rena') and kind = 'fcm'), 0::bigint);

select test.na_app('two', test.id('na_rena'));
insert into notifications (id, user_id, code, title, url, dedupe_key) values (test.id('na_n2'), test.id('na_rena'), 'renter_late_return_final', 'Late', '/account', 'na:n2');
update push_outbox set created_at = now() - interval '4 days', send_after = now() - interval '4 days' where notification_id = test.id('na_n2');
select app.server_push_due(200, array['web']);
select test.eq('an alert not sent within 3 days is dropped as stale (its kind had no sender)',
  (select count(*) || '/' || bool_and(status = 'failed' and last_error = 'not sent within 3 days') from push_outbox where notification_id = test.id('na_n2')), '2/true');
select test.eq('the app device turned off by its fcm: address', (app.push_unsubscribe(test.id('na_rena'), jsonb_build_object('endpoint', 'fcm:na-token-two-' || repeat('x', 40))) -> 'devices')::text not like '%fcm%', true);

-- ================================================================== Delete my account
select test.eq('asking: allowed for a renter, nothing asked yet', app.account_deletion_state(test.id('na_ravi'))::text, '{"allowed": true, "request": null}');
select app.request_account_deletion(test.id('na_ravi'), 'Moving away');
select test.eq('asked: an open request and a high Admin task for the renter, due in 14 days',
  (select d.status || '/' || t.queue || '/' || t.task_type || '/' || t.priority || '/' || (t.renter_id = test.id('renter:na_ravi')) || '/' || (t.due_at > now() + interval '13 days') || '/' || (t.detail like '%Reason: Moving away.%')
     from account_deletion_requests d join tasks t on t.id = d.task_id where d.user_id = test.id('na_ravi')), 'open/admin/account_deletion/high/true/true/true');
select app.request_account_deletion(test.id('na_ravi'));
select test.eq('asking again while open changes nothing', (select count(*) from account_deletion_requests where user_id = test.id('na_ravi')), 1::bigint);
select test.eq('withdrawn: the request closes', app.withdraw_account_deletion(test.id('na_ravi')) -> 'request' ->> 'status', 'withdrawn');
select test.eq('withdrawn: its task is cancelled', (select t.status from account_deletion_requests d join tasks t on t.id = d.task_id where d.user_id = test.id('na_ravi')), 'cancelled');
select app.request_account_deletion(test.id('na_ravi'));
update tasks set status = 'done', completed_at = now(), completed_by = test.id('na_admin')
 where id = (select task_id from account_deletion_requests where user_id = test.id('na_ravi') and status = 'open');
select test.eq('Done on the Admin''s task marks the request done', app.account_deletion_state(test.id('na_ravi')) -> 'request' ->> 'status', 'done');
select test.throws('an Admin account is closed by another Admin', $$select app.request_account_deletion(test.id('na_admin'))$$, 'another Admin');
select test.eq('an Admin sees no Delete my account', app.account_deletion_state(test.id('na_admin')) ->> 'allowed', 'false');

-- ================================================================== privileges
select test.ok('the server functions are not callable from a browser',
  not has_function_privilege('authenticated', 'public.server_request_account_deletion(uuid, text)', 'execute')
  and not has_function_privilege('anon', 'public.server_push_waiting(text[])', 'execute')
  and not has_function_privilege('authenticated', 'app.request_account_deletion(uuid, text)', 'execute')
  and has_function_privilege('service_role', 'public.server_push_due(integer, text[])', 'execute')
  and has_function_privilege('service_role', 'public.server_withdraw_account_deletion(uuid)', 'execute'));
select set_config('request.jwt.claim.sub', test.id('na_ravi')::text, false);
set role authenticated;
select test.eq('row security: a signed-in renter reads no deletion request, not even her own', (select count(*) from account_deletion_requests), 0::bigint);
reset role;
select set_config('request.jwt.claim.sub', '', false);
