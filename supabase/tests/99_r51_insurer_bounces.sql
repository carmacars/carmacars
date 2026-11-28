-- 99: R51 insurer emails that bounce (migration 5204, REQ-136; docs/changes/2026-11-27-r51-staff.md). An estimate to the
-- adjuster is refused by their mail server (550 5.7.129, an accept list): the version is marked bounced, the booking's claim
-- history says so, the Admins get one urgent To do with the allowlist request, and the estimate goes again once to the
-- insurer's claims email. Each version shows its delivery. Fixtures "ib51".
select test.suite('99 r51 insurer bounces: marked, logged, a To do, sent again to the claims email, the delivery shown');

select test.mk_user('ib51_admin', 'admin');
select test.mk_user('ib51_fin', 'va', 'finance');
insert into insurers (name, billing_email, claims_email, claims_phone) values ('IB51 Example Mutual', 'billing.ib51@example.test', 'claims.ib51@example.test', '+16475550161');
create table test.ib51 (k text primary key, v jsonb);
create function test.ib51v(p text) returns jsonb language sql stable as $$ select v from test.ib51 where k = p $$;
insert into test.ib51 select 'r', app.insurer_rental_create(test.id('ib51_admin'), jsonb_build_object('renter_name', 'Ib Example', 'insurer_id', (select id from insurers where name = 'IB51 Example Mutual'),
  'claim_number', 'IB51-1', 'adjuster_name', 'Ada Adjuster', 'adjuster_email', 'ada.adjuster@example.test', 'adjuster_phone', '+16475550162',
  'pickup_at', date_trunc('hour', now()) + interval '2 days', 'return_at', date_trunc('hour', now()) + interval '9 days',
  'car', jsonb_build_object('year', 2024, 'make', 'Kia', 'model', 'Forte', 'plate', 'IBF 051'), 'daily_rate_cents', 6000));
create function test.ib51b() returns uuid language sql stable as $$ select id from bookings where booking_number = test.ib51v('r') ->> 'booking_number' $$;
select app.insurer_invoice_save(test.id('ib51_fin'), jsonb_build_object('booking', test.ib51v('r') ->> 'booking_number',
  'lines', jsonb_build_array(jsonb_build_object('description', 'Replacement rental', 'quantity', 7, 'rate_cents', 6000))));
insert into test.ib51 select 'v1', app.insurer_invoice_send(test.id('ib51_fin'), jsonb_build_object('booking', test.ib51v('r') ->> 'booking_number', 'kind', 'estimate'));
select app.process_events(100000);
create function test.ib51o(p_to text) returns notification_outbox language sql stable as $$
  select * from notification_outbox where code = 'insurer_estimate' and lower(to_address) = p_to order by created_at desc limit 1 $$;
select test.eq('the estimate is queued to the adjuster', (test.ib51o('ada.adjuster@example.test')).audience, 'insurer');
update notification_outbox set status = 'sent', sent_at = now() - interval '1 hour' where id = (test.ib51o('ada.adjuster@example.test')).id;
create function test.ib51ver() returns insurer_invoice_versions language sql stable as $$
  select v.* from insurer_invoice_versions v join insurer_invoices i on i.id = v.invoice_id where i.booking_id = test.ib51b() order by v.version desc limit 1 $$;
create function test.ib51del() returns jsonb language sql stable as $$
  select x -> 'delivery' from jsonb_array_elements(app.insurer_rental_json(test.id('ib51_fin'), jsonb_build_object('booking', test.ib51v('r') ->> 'booking_number')) -> 'versions') x order by (x ->> 'version')::int desc limit 1 $$;
select test.eq('before any bounce: sent', test.ib51del() -> 0 ->> 'status', 'sent');

-- ================================================================ the bounce
select test.eq('a bounce for an address we never wrote to is ignored', public.server_email_bounce('{"to": "someone.else@example.test", "status": "5.7.129"}') ->> 'matched', 'false');
create temp table ib51_r as select public.server_email_bounce(jsonb_build_object('to', 'Ada.Adjuster@example.test', 'status', '5.7.129', 'ref', (test.ib51o('ada.adjuster@example.test')).id,
  'reason', 'The mailbox accepts only senders on its list: ask the insurer to add our sender address. 550 5.7.129 RESOLVER.RST.RestrictedToRecipientsPermission')) j;
select test.eq('matched to our estimate, an insurer email, sent again to the claims email', (select (j ->> 'matched') || '/' || (j ->> 'insurer') || '/' || (j ->> 'fallback_to') from ib51_r), 'true/true/claims.ib51@example.test');
select test.ok('the version is marked bounced with the reason', (test.ib51ver()).bounced_at is not null and (test.ib51ver()).bounce_reason like '5.7.129 %');
select test.eq('the version remembers where it went again', (test.ib51ver()).fallback_to, 'claims.ib51@example.test');
select test.ok('the booking''s claim history says so', exists (select 1 from booking_events where booking_id = test.ib51b() and kind = 'insurer_claim' and note like 'Email to ada.adjuster@example.test bounced%'));
select test.eq('one urgent Admin To do with the adjuster, the claims contact and the allowlist request',
  (select count(*) || '/' || bool_and(priority = 'urgent') || '/' || bool_and(queue = 'admin') || '/' || bool_and(detail like '%Ada Adjuster%' and detail like '%claims.ib51@example.test, +16475550161%'
            and detail like '%Please add % to the senders this mailbox accepts%' and detail like '%Blind Spot Car Rental%')
     from tasks where task_type = 'insurer_email_bounced' and booking_id = test.ib51b()), '1/true/true/true');
select test.ok('the allowlist request names the sender address and never the company name CarmaCars',
  (select detail ~ 'Please add \S+@\S+ to the senders' and split_part(detail, 'Allowlist request', 2) !~* 'carma ?cars[^.@]' from tasks where task_type = 'insurer_email_bounced' and booking_id = test.ib51b()));
select test.eq('the same bounce again changes nothing', public.server_email_bounce(jsonb_build_object('to', 'ada.adjuster@example.test', 'status', '5.7.129', 'ref', (test.ib51o('ada.adjuster@example.test')).id)) ->> 'repeat', 'true');
select test.eq('still one To do', (select count(*) from tasks where task_type = 'insurer_email_bounced' and booking_id = test.ib51b()), 1::bigint);
select test.eq('the address is not suppressed (an accept list ends once the insurer lists us)', (select count(*) from email_suppressions where email = 'ada.adjuster@example.test' and lifted_at is null), 0::bigint);

-- the estimate again, to the claims email (Blind Spot's email, the same version)
select app.process_events(100000);
select test.eq('the estimate goes again to the claims email', (test.ib51o('claims.ib51@example.test')).audience, 'insurer');
select test.eq('it names no CarmaCars in any value its template prints (the keys 99_r50i checks)',
  (select count(*) from notification_outbox o, unnest(array['amount', 'claim_number', 'company_address', 'first_name', 'insurer_name', 'invoice_amount', 'invoice_hst', 'invoice_number',
      'invoice_total', 'label', 'period', 'renter_name', 'reply_time', 'support_phone', 'vehicle_name', 'version']) k
    where o.id = (test.ib51o('claims.ib51@example.test')).id and coalesce(o.payload ->> k, '') || coalesce(o.to_name, '') ~* 'carma ?cars'), 0::bigint);
select test.eq('the delivery of the version: the adjuster bounced, the claims email queued (sent again)',
  (select string_agg((d ->> 'to') || ':' || (d ->> 'status') || ':' || (d ->> 'fallback'), ',' order by d ->> 'at') from jsonb_array_elements(test.ib51del()) d),
  'ada.adjuster@example.test:bounced:false,claims.ib51@example.test:queued:true');
-- a second bounce of the same version does not send it again (once a version)
update notification_outbox set status = 'sent', sent_at = now() - interval '2 days' where id = (test.ib51o('claims.ib51@example.test')).id;
select test.eq('delivered: sent with no bounce in 24 hours', (select d ->> 'status' from jsonb_array_elements(test.ib51del()) d where d ->> 'to' = 'claims.ib51@example.test'), 'delivered');
select test.eq('the claims email bounces too: no third send', public.server_email_bounce(jsonb_build_object('to', 'claims.ib51@example.test', 'status', '5.1.1')) ->> 'fallback_to', null::text);
select test.eq('the page shows the claims contact', app.insurer_rental_json(test.id('ib51_fin'), jsonb_build_object('booking', test.ib51v('r') ->> 'booking_number')) #>> '{claim,insurer_claims_email}', 'claims.ib51@example.test');
select test.eq('Settings, Insurers saves the claims contact', (select count(*) from unnest(array['claims_email', 'claims_phone']) c where pg_get_functiondef('app.admin_save_pre0780(uuid,text,jsonb)'::regprocedure) like '%''' || c || '''%'), 2::bigint);
select test.eq('the browser roles cannot report a bounce', has_function_privilege('authenticated', 'public.server_email_bounce(jsonb)', 'execute') or has_function_privilege('anon', 'public.server_email_bounce(jsonb)', 'execute'), false);

-- ================================================================ REQ-137: never from rent@carmacars.ca
select test.eq('every insurer email goes from the Blind Spot address', (select string_agg(distinct coalesce(substring(from_address from '<([^>]+)>'), from_address), ',') from notification_catalogue
  where audience = 'insurer'), 'blindspotcarrental@carmacars.ca');
select test.throws('the catalogue refuses rent@ for an insurer email', $$update notification_catalogue set reply_to = 'rent@carmacars.ca' where code = 'insurer_invoice'$$, '%never go from rent@carmacars.ca%');
select test.throws('the reply-to rules refuse rent@ for insurers', $$insert into email_reply_to (audience, reply_to) values ('insurer', 'Rent@CarmaCars.ca')$$, '%never go from rent@carmacars.ca%');
select test.throws('a queued insurer email cannot carry rent@ as its reply-to', $$update notification_outbox set reply_to = 'rent@carmacars.ca' where id = (test.ib51o('claims.ib51@example.test')).id$$, '%never go from rent@carmacars.ca%');
select test.lives('other emails keep their own reply-to', $$update email_reply_to set reply_to = reply_to where audience = 'renter'$$);
