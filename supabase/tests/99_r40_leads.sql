-- 99: migration 2411 (release 40): the renter context on the lead, signals for the whole person, bulk assignment of leads.
-- Fixtures: "zl". Test data only (example.test addresses, 555 numbers).
select test.suite('99 r40 renter context, person signals, bulk assignment (2411)');
grant usage on schema test to service_role;

select test.mk_user('zl_admin', 'admin');
select test.mk_user('zl_sales', 'va', 'sales');
select test.mk_user('zl_sales2', 'va', 'sales');
select test.mk_user('zl_cs', 'va', 'cs');
update staff_profiles set quo_user_id = 'USZLCS1' where user_id = test.id('zl_cs');
update sales_lead_settings set claim_cooldown_minutes = 0, lead_cap_base = 1, lead_cap_max = 1, claim_minutes = '{"renter": 15, "owner": 15, "partner": 15}'::jsonb, lead_cs_hold_minutes = null;
update program_settings set phone_enabled = true;

create function pg_temp.dr(p_user text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb language sql as
$$ select public.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;
create function pg_temp.lead(p_label text, p_email text, p_phone text, p_age interval default interval '0') returns uuid language sql as $$
  insert into leads (id, kind, name, email, phone, source, message, created_at)
  values (test.id('lead:zl' || p_label), 'contact', 'Lead ' || p_label, p_email, p_phone, 'web', 'I need an SUV for 2 weeks', now() - p_age) returning id $$;
create function pg_temp.ctx(p_user text, p_label text) returns jsonb language sql as
$$ select pg_temp.dr(p_user, case when p_user = 'zl_admin' then 'admin_read' else 'va_read' end, 'lead_context', jsonb_build_object('lead', test.id('lead:zl' || p_label))) $$;

-- ---------------------------------------------------------------- the person: a renter with a booking, a review, a visit, a call
select test.mk_owner('zl_owner');
select test.mk_vehicle('zl_car', 'zl_owner');
select test.mk_renter('zl_r');
update renters set mobile = '+14165558801', created_at = now() - interval '2 years' where id = test.id('renter:zl_r');
select test.mk_booking('ZL-1', 'zl_car', 'zl_r', '2024-03-04 10:00', '2024-03-08 10:00', 'closed');
insert into reviews (booking_id, renter_id, vehicle_id, rating, title, body, status) values (test.id('booking:ZL-1'), test.id('renter:zl_r'), test.id('vehicle:zl_car'), 5, 'Great car', 'Smooth pickup', 'pending');
insert into visitor_sessions (id, visitor_id, renter_id, started_at, last_seen_at, page_views, cars_viewed) values (test.id('ses:zl'), test.id('vis:zl'), test.id('renter:zl_r'), now() - interval '1 hour', now() - interval '50 minutes', 6, array[test.id('vehicle:zl_car')]);
insert into visitor_events (session_id, at, kind, vehicle_id) values (test.id('ses:zl'), now() - interval '55 minutes', 'car_view', test.id('vehicle:zl_car')), (test.id('ses:zl'), now() - interval '54 minutes', 'quote_seen', test.id('vehicle:zl_car'));
-- the lead (by the renter's email) and an earlier lead with the renter's phone
select pg_temp.lead('a', 'zl_r@example.test', null);
select pg_temp.lead('old', null, '416-555-8801', interval '20 days');
-- a call on the earlier lead's number
select app.server_phone_event(jsonb_build_object('type', 'call.completed', 'event_id', 'EVZL1', 'call_id', 'ACZL1', 'quo_id', 'ACZL1', 'direction', 'in',
  'their_number', '+14165558801', 'at', now() - interval '2 hours', 'status', 'completed', 'answered_at', now() - interval '2 hours', 'completed_at', now() - interval '2 hours', 'duration', 125));

select test.eq('person: the lead finds the renter by email', (app.person_keys(null, test.id('lead:zla')) ->> 'renter_id')::uuid, test.id('renter:zl_r'));
select test.ok('person: the earlier lead with the renter''s phone is the same person',
  test.id('lead:zlold') = any (app.pk_uuids(app.person_keys(null, test.id('lead:zla')), 'leads')));
select test.eq('person: the earlier lead and the renter resolve to the same leads',
  (select array_agg(x order by x) from unnest(app.pk_uuids(app.person_keys(null, test.id('lead:zlold')), 'leads')) x),
  (select array_agg(x order by x) from unnest(app.pk_uuids(app.person_keys(test.id('renter:zl_r'), null), 'leads')) x));

-- ---------------------------------------------------------------- the signals are the person's
select test.eq('behaviour: a rental, a car viewed, a quote seen, a visit, a review, both leads',
  (select concat_ws('/', b ->> 'rentals', b ->> 'cars', b ->> 'offers_viewed', b ->> 'visits', b ->> 'review_avg', b ->> 'leads')
     from (select app.person_behaviour(app.person_keys(null, test.id('lead:zla'))) b) x), '1/1/1/1/5.0/2');
select test.eq('intent: the lead and its renter read the same behaviour',
  app.intent_inputs('lead', test.id('lead:zla')) -> 'behaviour', app.intent_inputs('renter', test.id('renter:zl_r')) -> 'behaviour');
select test.ok('intent: the call on the earlier lead''s number counts for this lead',
  coalesce((app.intent_inputs('lead', test.id('lead:zla')) #>> '{behaviour,conversations}')::int, 0) >= 1);
select test.ok('intent score: rented before and a quote opened are reasons',
  (select count(*) from jsonb_array_elements(app.intent_compute('lead', test.id('lead:zla')) -> 'reasons') r where r ->> 'label' in ('Rented with us before (1)', 'Opened an offer or a quote')) = 2);
select test.eq('signals timeline: call, quote, car, visit, booking, returned, review and both leads are there, newest first',
  (select string_agg(distinct s ->> 'type', ',' order by s ->> 'type') from jsonb_array_elements(app.person_signals(app.person_keys(null, test.id('lead:zla')))) s),
  'booking,call,car_view,lead,quote_seen,rented,review,visit');
select test.ok('signals timeline: the call shows its length',
  exists (select 1 from jsonb_array_elements(app.person_signals(app.person_keys(null, test.id('lead:zla')))) s where s ->> 'type' = 'call' and s ->> 'detail' like '2 min 5 s%'));

-- ---------------------------------------------------------------- the context: Admin
select test.eq('Admin: full context', (pg_temp.ctx('zl_admin', 'a') ->> 'full'), 'true');
select test.eq('Admin: the booking with its car, status and total',
  (select (b ->> 'number') || '/' || (b ->> 'status') || '/' || ((b ->> 'total_cents')::bigint > 0)::text from jsonb_array_elements(pg_temp.ctx('zl_admin', 'a') -> 'bookings') b), 'ZL-1/closed/true');
select test.eq('Admin: both leads, this one marked', (select count(*)::text || '/' || count(*) filter (where (x ->> 'this')::boolean)::text from jsonb_array_elements(pg_temp.ctx('zl_admin', 'a') -> 'leads') x), '2/1');
select test.eq('Admin: licence verified yes, the review, the signals', (select concat_ws('/', c #>> '{account,licence_verified}', jsonb_array_length(c -> 'reviews'), (jsonb_array_length(c -> 'signals') >= 6)::text)
  from (select pg_temp.ctx('zl_admin', 'a') c) x), 'true/1/true');
select test.ok('never a licence number, a card or a date of birth in the context',
  (select position(d.licence_number in pg_temp.ctx('zl_admin', 'a')::text) = 0 and position('4242' in pg_temp.ctx('zl_admin', 'a')::text) = 0
          and position('1990-05-05' in pg_temp.ctx('zl_admin', 'a')::text) = 0 from drivers d where d.id = test.id('driver:zl_r')));
select test.ok('the deposit, the balance and the activity log are there', (select c ? 'deposit' and c ? 'balance' and jsonb_typeof(c -> 'activity') = 'array' from (select pg_temp.ctx('zl_admin', 'a') c) x));

-- ---------------------------------------------------------------- the context: staff (the renter is outside their window)
select test.eq('Sales, not their lead: the contact and counts only', (select concat_ws('/', c ->> 'full', (c ? 'bookings')::text, c #>> '{counts,bookings}', (c ->> 'why_limited' like 'Claim the lead%')::text)
  from (select pg_temp.ctx('zl_sales', 'a') c) x), 'false/false/1/true');
select test.eq('Sales, not their lead: no opening logged', (select count(*) from data_access_log where user_id = test.id('zl_sales') and renter_id = test.id('renter:zl_r')), 0::bigint);
select pg_temp.dr('zl_sales', 'va_do', 'lead_claim', jsonb_build_object('lead', test.id('lead:zla')));
select test.eq('Sales, their claim: the full context', (pg_temp.ctx('zl_sales', 'a') ->> 'full'), 'true');
select test.eq('Sales, their claim: the opening is logged with the reason (24 hours)',
  (select count(*)::text || '/' || bool_and(reason like 'Working lead%' and granted_until > now() + interval '23 hours')::text from data_access_log where user_id = test.id('zl_sales') and renter_id = test.id('renter:zl_r')), '1/true');
select test.ok('Sales, their claim: they handled them ("Claimed the lead")',
  exists (select 1 from jsonb_array_elements(pg_temp.ctx('zl_sales', 'a') -> 'handled_by') h where (h ->> 'id')::uuid = test.id('zl_sales') and h -> 'what' ? 'Claimed the lead'));
select test.throws('someone who cannot see leads cannot read it', format($$select app.lead_context(%L, jsonb_build_object('lead', %L))$$, test.id('renter:zl_r'), test.id('lead:zla')), 'Leads are for Admins');
select pg_temp.dr('zl_sales', 'va_do', 'lead_unclaim', jsonb_build_object('lead', test.id('lead:zla')));

-- ---------------------------------------------------------------- bulk assignment
select pg_temp.lead('b1', 'zlb1.lead@example.test', null, interval '3 days');
select pg_temp.lead('b2', 'zlb2.lead@example.test', null, interval '2 days');
select pg_temp.lead('b3', 'zlb3.lead@example.test', null, interval '0');
select test.throws('bulk: Admins only', format($$select pg_temp.dr('zl_sales', 'va_do', 'leads_bulk_assign', jsonb_build_object('ids', jsonb_build_array(%L), 'to', %L))$$, test.id('lead:zlb1'), test.id('zl_sales')), null);
select test.throws('bulk: customer service cannot take leads', format($$select pg_temp.dr('zl_admin', 'admin_do', 'leads_bulk_assign', jsonb_build_object('ids', jsonb_build_array(%L), 'to', %L))$$, test.id('lead:zlb1'), test.id('zl_cs')), 'cannot take leads');
select test.throws('bulk: a person or the pool is needed', format($$select pg_temp.dr('zl_admin', 'admin_do', 'leads_bulk_assign', jsonb_build_object('ids', jsonb_build_array(%L)))$$, test.id('lead:zlb1')), 'Choose who gets the leads');
select test.throws('bulk: at most 500 chosen at once', format($$select pg_temp.dr('zl_admin', 'admin_do', 'leads_bulk_assign', jsonb_build_object('ids', (select jsonb_agg(gen_random_uuid()) from generate_series(1, 501)), 'to', %L))$$, test.id('zl_sales')), 'At most 500');
select test.ok('the Assign to choices: Sales yes, customer service and Admins no',
  (select bool_or((a ->> 'id')::uuid = test.id('zl_sales')) and not bool_or((a ->> 'id')::uuid in (test.id('zl_cs'), test.id('zl_admin')))
     from jsonb_array_elements(pg_temp.dr('zl_admin', 'admin_read', 'sales_leads', '{}'::jsonb) -> 'assignees') a));
select test.eq('bulk preview: counts and changes nothing',
  (pg_temp.dr('zl_admin', 'admin_do', 'leads_bulk_assign', jsonb_build_object('ids', jsonb_build_array(test.id('lead:zlb1'), test.id('lead:zlb2')), 'to', test.id('zl_sales'), 'preview', true)) ->> 'matched')
   || '/' || (select count(*) from leads where id in (test.id('lead:zlb1'), test.id('lead:zlb2')) and assigned_to is not null), '2/0');
select test.eq('bulk by choice: both assigned',
  pg_temp.dr('zl_admin', 'admin_do', 'leads_bulk_assign', jsonb_build_object('ids', jsonb_build_array(test.id('lead:zlb1'), test.id('lead:zlb2')), 'to', test.id('zl_sales'))) ->> 'changed', '2');
select test.eq('bulk: an Admin assignment, not a claim and not a hold, logged as assign',
  (select concat_ws('/', count(*) filter (where l.assigned_to = test.id('zl_sales') and l.admin_assigned_by = test.id('zl_admin')),
     (select count(*) from lead_claims c where c.lead_id in (test.id('lead:zlb1'), test.id('lead:zlb2'))),
     (select count(*) from lead_holds h where h.lead_id in (test.id('lead:zlb1'), test.id('lead:zlb2'))),
     (select count(*) from lead_claim_log g where g.lead_id in (test.id('lead:zlb1'), test.id('lead:zlb2')) and g.action = 'assign' and g.by_user = test.id('zl_admin')))
   from leads l where l.id in (test.id('lead:zlb1'), test.id('lead:zlb2'))), '2/0/0/2');
select test.ok('bulk: one audit log entry with the leads', exists (select 1 from audit_log a where a.action = 'leads_bulk_assign' and a.actor_user_id = test.id('zl_admin') and a.after -> 'leads' ? test.id('lead:zlb1')::text));
select test.eq('bulk: the rows say it is an Admin assignment',
  (select x ->> 'admin_assigned' from jsonb_array_elements(pg_temp.dr('zl_admin', 'admin_read', 'sales_leads', '{"status": "all", "q": "zlb1.lead"}'::jsonb) -> 'rows') x where x ->> 'id' = test.id('lead:zlb1')::text), 'true');
select test.eq('bulk again: nothing changes the second time', pg_temp.dr('zl_admin', 'admin_do', 'leads_bulk_assign', jsonb_build_object('ids', jsonb_build_array(test.id('lead:zlb1')), 'to', test.id('zl_sales'))) ->> 'unchanged', '1');
select test.throws('another salesperson cannot claim an assigned lead', format($$select pg_temp.dr('zl_sales2', 'va_do', 'lead_claim', jsonb_build_object('lead', %L))$$, test.id('lead:zlb1')), 'An Admin assigned this lead to');
select test.ok('Next lead skips leads assigned to someone else',
  coalesce(pg_temp.dr('zl_sales2', 'va_do', 'lead_next', '{}'::jsonb) ->> 'lead', '') not in (test.id('lead:zlb1')::text, test.id('lead:zlb2')::text));
select pg_temp.dr('zl_sales2', 'va_do', 'lead_unclaim', jsonb_build_object('lead', (select lead_id from lead_claims where claimed_by = test.id('zl_sales2') limit 1)))
 where exists (select 1 from lead_claims where claimed_by = test.id('zl_sales2'));
select test.lives('the assignee claims both, past their cap of 1 (assigned leads are not capped)',
  format($$select pg_temp.dr('zl_sales', 'va_do', 'lead_claim', jsonb_build_object('lead', %L)), pg_temp.dr('zl_sales', 'va_do', 'lead_claim', jsonb_build_object('lead', %L))$$, test.id('lead:zlb1'), test.id('lead:zlb2')));
-- a customer service call hold over it gives it back to the assignee
update leads set phone = '+14165558802' where id = test.id('lead:zlb1');
select app.server_phone_event(jsonb_build_object('type', 'call.completed', 'event_id', 'EVZL2', 'call_id', 'ACZL2', 'quo_id', 'ACZL2', 'direction', 'in',
  'their_number', '+14165558802', 'at', now(), 'status', 'completed', 'answered_at', now(), 'completed_at', now(), 'duration', 60, 'user_id', 'USZLCS1'));
select test.eq('a call hold still works over an assigned lead', (select held_by from lead_holds where lead_id = test.id('lead:zlb1')), test.id('zl_cs'));
update lead_holds set expires_at = now() - interval '1 minute' where lead_id = test.id('lead:zlb1');
select app.sl_expire();
select test.eq('the hold ends: back to the assignee, still assigned',
  (select c.claimed_by::text || '/' || (l.admin_assigned_at is not null)::text from leads l left join lead_claims c on c.lead_id = l.id where l.id = test.id('lead:zlb1')), test.id('zl_sales')::text || '/true');

-- by filter: every open unassigned lead created before today (b3 is today's)
select test.eq('bulk by filter (before today, unassigned): preview',
  (pg_temp.dr('zl_admin', 'admin_do', 'leads_bulk_assign', '{"filter": {"before_today": true, "assigned": "none", "status": "unclaimed"}, "pool": true, "preview": true}'::jsonb) ->> 'matched')::int
   = (select count(*) from leads l where l.created_at < (date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto') and l.assigned_to is null and l.handled_at is null
        and l.status in ('new', 'contacted', 'qualified') and coalesce(l.sales_outcome, '') not in ('won', 'lost') and app.sl_listed(l)
        and not exists (select 1 from lead_claims c where c.lead_id = l.id and c.expires_at > now()) and not exists (select 1 from lead_holds h where h.lead_id = l.id and h.expires_at > now()))::int, true);
select pg_temp.dr('zl_admin', 'admin_do', 'leads_bulk_assign', jsonb_build_object('filter', jsonb_build_object('before_today', true, 'assigned', 'none', 'status', 'unclaimed'), 'to', test.id('zl_sales2')));
select test.eq('bulk by filter: the earlier lead went, today''s did not',
  (select string_agg(coalesce(assigned_to::text, 'none'), ',' order by created_at) from leads where id in (test.id('lead:zlold'), test.id('lead:zlb3'))), test.id('zl_sales2')::text || ',none');
-- the cap: 500 a call, the rest left for the next press
insert into leads (kind, name, email, source, created_at) select 'contact', 'Lead zl bulk ' || g, 'zlbulk' || g || '.lead@example.test', 'web', now() - interval '5 days' from generate_series(1, 502) g;
select test.eq('bulk: at most 500 a call, the rest reported as left',
  (select (r ->> 'changed') || '/' || ((r ->> 'left')::int >= 2)::text from (select pg_temp.dr('zl_admin', 'admin_do', 'leads_bulk_assign', jsonb_build_object('filter', jsonb_build_object('q', 'lead zl bulk', 'assigned', 'none'), 'to', test.id('zl_sales2'))) r) x), '500/true');
-- back to the pool
select test.eq('Return to the pool: one lead changed', pg_temp.dr('zl_admin', 'admin_do', 'leads_bulk_assign', jsonb_build_object('ids', jsonb_build_array(test.id('lead:zlb2')), 'pool', true)) ->> 'changed', '1');
select test.eq('Return to the pool: assignment and claim gone, logged as release',
  (select coalesce(assigned_to::text, 'none') || '/' || (admin_assigned_at is null)::text from leads where id = test.id('lead:zlb2'))
     || '/' || (select count(*) from lead_claims where lead_id = test.id('lead:zlb2'))
     || '/' || (select count(*) from lead_claim_log where lead_id = test.id('lead:zlb2') and action = 'release' and note like 'Returned to the pool%'), 'none/true/0/1');
select test.lives('in the pool, anyone may claim it again', format($$select pg_temp.dr('zl_sales2', 'va_do', 'lead_claim', jsonb_build_object('lead', %L))$$, test.id('lead:zlb2')));
-- an Admin's single Reassign ends the Admin assignment (it is a claim, as before)
select pg_temp.dr('zl_admin', 'admin_do', 'lead_reassign', jsonb_build_object('lead', test.id('lead:zlold'), 'to', test.id('zl_sales')));
select test.eq('Reassign: a claim again, no longer an Admin assignment', (select (admin_assigned_at is null)::text || '/' || assigned_to::text from leads where id = test.id('lead:zlold')), 'true/' || test.id('zl_sales')::text);
