-- 99: migration 2320 (release 37): a lead handled on a phone call by customer service or fleet is held for them for a while.
-- Taken by answering or placing a call (Quo, the site's Call button), a note (the lead, the caller pop-up) or Create lead from a
-- call; extended by every new handled call; Sales are blocked meanwhile (claim, contact, outcome, Call, text), Next lead leaves
-- it out; the end returns the lead to who held a claim, the salesperson who brought it, or the pool; an Admin releases it early;
-- someone not fully onboarded never holds; the hold is not a claim, so nobody in customer service is credited. Fixtures: "zh".
select test.suite('99 r37 customer service lead hold (2320)');
grant usage on schema test to service_role;

select test.mk_user('zh_admin', 'admin');
select test.mk_user('zh_cs', 'va', 'cs');
select test.mk_user('zh_cs2', 'va', 'cs');
select test.mk_user('zh_fleet', 'va', 'fleet');
select test.mk_user('zh_sales', 'va', 'sales');
select test.mk_user('zh_sales2', 'va', 'sales');
select test.mk_user('zh_new', 'va', 'cs');
update staff_profiles set quo_user_id = 'USZHCS1' where user_id = test.id('zh_cs');
update staff_profiles set quo_user_id = 'USZHFL1' where user_id = test.id('zh_fleet');
update staff_profiles set quo_user_id = 'USZHNEW' where user_id = test.id('zh_new');
update users set phone = '+14165550101' where id = test.id('zh_cs');
update users set phone = '+14165550102' where id = test.id('zh_sales');
update sales_lead_settings set claim_cooldown_minutes = 0, lead_cap_base = 20, lead_cap_max = 20, claim_minutes = '{"renter": 15, "owner": 15, "partner": 15}'::jsonb, lead_cs_hold_minutes = null;
update program_settings set phone_enabled = true;

create function pg_temp.dr(p_user text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb language sql as
$$ select public.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;
create function pg_temp.lead(p_label text, p_phone text default null, p_sourced text default null) returns uuid language sql as $$
  insert into leads (id, kind, name, email, phone, source, sourced_by)
  values (test.id('lead:zh' || p_label), 'contact', 'Lead ' || p_label, 'zh' || p_label || '.lead@example.test', p_phone, 'web', case when p_sourced is not null then test.id(p_sourced) end) returning id $$;
-- a Quo call by a Quo user (answered): from a number
create function pg_temp.call(p_id text, p_number text, p_quo text, p_dir text default 'in') returns void language sql as $$
  select app.server_phone_event(jsonb_build_object('type', 'call.completed', 'event_id', 'EV' || p_id, 'call_id', p_id, 'quo_id', p_id, 'direction', p_dir,
    'their_number', p_number, 'at', now(), 'status', 'completed', 'answered_at', now(), 'completed_at', now(), 'duration', 60, 'user_id', p_quo)) $$;
create function pg_temp.hold(p_label text) returns lead_holds language sql as $$ select * from lead_holds where lead_id = test.id('lead:zh' || p_label) $$;
create function pg_temp.log(p_label text, p_action text) returns bigint language sql as $$
  select count(*) from lead_claim_log where lead_id = test.id('lead:zh' || p_label) and action = p_action $$;

-- ---------------------------------------------------------------- 1. a Quo call answered by customer service holds the lead
select pg_temp.lead('a', '+14165559001');
select pg_temp.call('ACZH1', '+14165559001', 'USZHCS1');
select test.eq('answered call: the lead is held by customer service', (select held_by::text || '/' || role from pg_temp.hold('a')), test.id('zh_cs')::text || '/cs');
select test.eq('answered call: the window is the Sales claim window (15 min) by default',
  (select round(extract(epoch from expires_at - now()) / 60)::int from pg_temp.hold('a')), 15);
select test.eq('answered call: logged as a hold by role', (select hold_role || '/' || user_id::text from lead_claim_log where lead_id = test.id('lead:zha') and action = 'hold'), 'cs/' || test.id('zh_cs')::text);
select test.eq('answered call: nobody is credited a claim', (select count(*) from lead_claims where lead_id = test.id('lead:zha')), 0::bigint);
select test.eq('answered call: assigned_to is untouched', (select assigned_to from leads where id = test.id('lead:zha')), null::uuid);

-- a missed call does not hold
select pg_temp.lead('miss', '+14165559002');
select app.server_phone_event(jsonb_build_object('type', 'call.missed', 'event_id', 'EVmiss', 'call_id', 'ACZHM', 'quo_id', 'ACZHM', 'direction', 'in', 'their_number', '+14165559002',
  'at', now(), 'status', 'missed', 'user_id', 'USZHCS1'));
select test.eq('missed call: no hold', (select count(*) from lead_holds where lead_id = test.id('lead:zhmiss')), 0::bigint);

-- ---------------------------------------------------------------- 2. Sales see it and are blocked
select test.eq('Sales see who is handling it: first name, role, until',
  (select (r #>> '{hold,first_name}') || '/' || (r #>> '{hold,role_label}') || '/' || (r #>> '{hold,locked}') || '/' || ((r #>> '{hold,until}') is not null)::text
     from (select pg_temp.dr('zh_sales', 'va_read', 'sales_lead', jsonb_build_object('id', test.id('lead:zha'))) r) x), 'Zh/Customer service/true/true');
select test.eq('the list rows carry the hold too',
  (select (x #>> '{hold,first_name}') from jsonb_array_elements(pg_temp.dr('zh_sales', 'va_read', 'sales_leads', '{}'::jsonb) -> 'rows') x where x ->> 'id' = test.id('lead:zha')::text), 'Zh');
select test.eq('the holder sees it as theirs (not locked)',
  (select r #>> '{hold,locked}' from (select pg_temp.dr('zh_cs', 'va_read', 'sales_lead', jsonb_build_object('id', test.id('lead:zha'))) r) x), 'false');
select test.throws('Sales cannot claim it', format($$select pg_temp.dr('zh_sales', 'va_do', 'lead_claim', jsonb_build_object('lead', %L))$$, test.id('lead:zha')), 'Being handled by Zh (Customer service) until');
select test.throws('Sales cannot log a call on it', format($$select pg_temp.dr('zh_sales', 'va_do', 'lead_contact', jsonb_build_object('lead', %L, 'channel', 'call'))$$, test.id('lead:zha')), 'Being handled by Zh');
select test.throws('Sales cannot log a text on it', format($$select pg_temp.dr('zh_sales', 'va_do', 'lead_contact', jsonb_build_object('lead', %L, 'channel', 'text'))$$, test.id('lead:zha')), 'Being handled by Zh');
select test.throws('Sales cannot log an email on it', format($$select pg_temp.dr('zh_sales', 'va_do', 'lead_contact', jsonb_build_object('lead', %L, 'channel', 'email'))$$, test.id('lead:zha')), 'Being handled by Zh');
select test.throws('Sales cannot set an outcome', format($$select pg_temp.dr('zh_sales', 'va_do', 'lead_outcome', jsonb_build_object('lead', %L, 'outcome', 'contacted'))$$, test.id('lead:zha')), 'Being handled by Zh');
select test.throws('Sales cannot mark it handled', format($$select pg_temp.dr('zh_sales', 'va_do', 'lead_handled', jsonb_build_object('lead', %L))$$, test.id('lead:zha')), 'Being handled by Zh');
select test.throws('Sales cannot press Call (the site''s Call button)', format($$select app.server_twilio_call_start(jsonb_build_object('user_id', %L, 'number', '+14165559001'))$$, test.id('zh_sales')), 'Being handled by Zh');
select test.throws('Sales cannot text it from the inbox', format($$select app.phone_staff_do(%L, 'phone_reply', jsonb_build_object('id', %L, 'body', 'Hello'))$$,
  test.id('zh_sales'), (select id from phone_threads where number = '+14165559001')), 'Being handled by Zh');
select test.ok('Next lead leaves held leads out', (select coalesce(pg_temp.dr('zh_sales', 'va_do', 'lead_next', '{}'::jsonb) ->> 'lead', '') not in (test.id('lead:zha')::text, test.id('lead:zhb')::text, test.id('lead:zhc')::text)));
select test.eq('the list: Claimed includes it, Not claimed leaves it out',
  (select (select count(*) from jsonb_array_elements(pg_temp.dr('zh_sales', 'va_read', 'sales_leads', '{"status": "claimed"}'::jsonb) -> 'rows') x where x ->> 'id' = test.id('lead:zha')::text)::text
       || '/' || (select count(*) from jsonb_array_elements(pg_temp.dr('zh_sales', 'va_read', 'sales_leads', '{"status": "unclaimed"}'::jsonb) -> 'rows') x where x ->> 'id' = test.id('lead:zha')::text)::text), '1/0');
select test.lives('another customer service person may still work it (a note takes the hold over)',
  format($$select pg_temp.dr('zh_cs2', 'va_do', 'lead_contact', jsonb_build_object('lead', %L, 'channel', 'note', 'note', 'Called back'))$$, test.id('lead:zha')));
select test.eq('the take-over: the hold is theirs, the first one ended in the log', (select held_by::text from pg_temp.hold('a')) || '/' || pg_temp.log('a', 'hold_end')::text, test.id('zh_cs2')::text || '/1');
select test.throws('an Admin''s claim needs the hold released first', format($$select pg_temp.dr('zh_admin', 'admin_do', 'lead_claim', jsonb_build_object('lead', %L))$$, test.id('lead:zha')), 'Release the hold first');

-- ---------------------------------------------------------------- 3. every new handled call extends it
select pg_temp.lead('b', '+14165559003');
select pg_temp.call('ACZH2', '+14165559003', 'USZHCS1');
update lead_holds set expires_at = now() + interval '2 minutes' where lead_id = test.id('lead:zhb');
select pg_temp.call('ACZH3', '+14165559003', 'USZHCS1');
select test.eq('a second answered call extends the hold to a full window', (select round(extract(epoch from expires_at - now()) / 60)::int from pg_temp.hold('b')), 15);
select test.eq('the extension is logged', pg_temp.log('b', 'hold_extend'), 1::bigint);
-- placing a call from the site extends it as well
update lead_holds set expires_at = now() + interval '2 minutes' where lead_id = test.id('lead:zhb');
select app.server_twilio_call_start(jsonb_build_object('user_id', test.id('zh_cs'), 'number', '+14165559003'));
select test.eq('the Call button extends it', (select round(extract(epoch from expires_at - now()) / 60)::int from pg_temp.hold('b')), 15);
select test.eq('the Call button was allowed to the holder', pg_temp.log('b', 'hold_extend'), 2::bigint);

-- the setting: its own window
update sales_lead_settings set lead_cs_hold_minutes = 40;
select pg_temp.lead('c', '+14165559004');
select pg_temp.call('ACZH4', '+14165559004', 'USZHCS1');
select test.eq('Program setting: lead_cs_hold_minutes sets the window', (select round(extract(epoch from expires_at - now()) / 60)::int from pg_temp.hold('c')), 40);
select test.eq('Program setting: saved by an Admin and read back',
  (pg_temp.dr('zh_admin', 'admin_do', 'sales_lead_settings_save', '{"lead_cs_hold_minutes": "25"}'::jsonb) ->> 'lead_cs_hold_minutes'), '25');
select test.eq('Program setting: emptied means the Sales window again',
  coalesce(pg_temp.dr('zh_admin', 'admin_do', 'sales_lead_settings_save', '{"lead_cs_hold_minutes": ""}'::jsonb) ->> 'lead_cs_hold_minutes', 'null'), 'null');
update sales_lead_settings set lead_cs_hold_minutes = null;

-- ---------------------------------------------------------------- 4. expiry returns the lead
-- (1) a salesperson held a claim: it comes back to them
select pg_temp.lead('d', '+14165559005');
select pg_temp.dr('zh_sales', 'va_do', 'lead_claim', jsonb_build_object('lead', test.id('lead:zhd')));
select pg_temp.call('ACZH5', '+14165559005', 'USZHCS1');
select test.eq('over a Sales claim: the hold replaces it', (select count(*) from lead_claims where lead_id = test.id('lead:zhd')) || '/' || (select prev_claimed_by::text from pg_temp.hold('d')), '0/' || test.id('zh_sales')::text);
update lead_holds set expires_at = now() - interval '1 minute' where lead_id = test.id('lead:zhd');
select pg_temp.dr('zh_sales2', 'va_read', 'sales_leads', '{}'::jsonb);
select test.eq('expiry: back to the salesperson who had it (a claim, logged as return)',
  (select claimed_by::text from lead_claims where lead_id = test.id('lead:zhd')) || '/' || pg_temp.log('d', 'return')::text, test.id('zh_sales')::text || '/1');
select test.eq('expiry: the hold is gone and its end logged', (select count(*) from lead_holds where lead_id = test.id('lead:zhd')) || '/' || pg_temp.log('d', 'hold_end'), '0/1');
-- (2) a lead a salesperson brought: back to them
select pg_temp.lead('e', '+14165559006', 'zh_sales2');
select pg_temp.call('ACZH6', '+14165559006', 'USZHCS1');
update lead_holds set expires_at = now() - interval '1 minute' where lead_id = test.id('lead:zhe');
select app.sl_expire();
select test.eq('expiry: back to the salesperson who brought it', (select claimed_by from lead_claims where lead_id = test.id('lead:zhe')), test.id('zh_sales2'));
-- (3) nobody had it: the pool, where Next lead finds it again
select pg_temp.lead('f', '+14165559007');
select pg_temp.call('ACZH7', '+14165559007', 'USZHCS1');
update lead_holds set expires_at = now() - interval '1 minute' where lead_id = test.id('lead:zhf');
select app.sl_expire();
select test.eq('expiry: to the pool, no claim', (select count(*) from lead_claims where lead_id = test.id('lead:zhf')) || '/' || (select count(*) from lead_holds where lead_id = test.id('lead:zhf')), '0/0');
select test.lives('after expiry Sales may claim it', format($$select pg_temp.dr('zh_sales', 'va_do', 'lead_claim', jsonb_build_object('lead', %L))$$, test.id('lead:zhf')));

-- ---------------------------------------------------------------- 5. fleet, notes, the caller pop-up, Create lead
select pg_temp.lead('g', '+14165559008');
select pg_temp.call('ACZH8', '+14165559008', 'USZHFL1', 'out');
select test.eq('fleet placing a call (Quo) holds the lead, role fleet', (select role from pg_temp.hold('g')), 'fleet');
select test.throws('the words name the role', format($$select pg_temp.dr('zh_sales', 'va_do', 'lead_claim', jsonb_build_object('lead', %L))$$, test.id('lead:zhg')), 'Being handled by Zh (Fleet) until');

select pg_temp.lead('h');
select test.eq('a note on the lead by customer service holds it', (pg_temp.dr('zh_cs', 'va_do', 'lead_contact', jsonb_build_object('lead', test.id('lead:zhh'), 'channel', 'note', 'note', 'Phoned, will call back')) ->> 'lead')::uuid, test.id('lead:zhh'));
select test.eq('...held by them, with no Sales-style claim', (select held_by::text from pg_temp.hold('h')) || '/' || (select count(*) from lead_claims where lead_id = test.id('lead:zhh')), test.id('zh_cs')::text || '/0');
select test.eq('a text logged by customer service does not hold', (pg_temp.dr('zh_cs2', 'va_do', 'lead_contact', jsonb_build_object('lead', test.id('lead:zhg'), 'channel', 'text')) ->> 'lead')::uuid, test.id('lead:zhg'));

-- the caller pop-up: a note on a renter who is also an open lead
select test.mk_renter('zh_r');
update renters set mobile = '(416) 555-9009', email = 'zhzh_r.lead@example.test' where id = test.id('renter:zh_r');
select pg_temp.lead('zh_r');
select pg_temp.call('ACZH9', '+14165559009', null);
select test.eq('pop-up note: the renter''s open lead (same email) is held by the note''s author',
  (select (pg_temp.dr('zh_cs', 'va_do', 'renter_note_add', jsonb_build_object('renter_id', test.id('renter:zh_r'), 'body', 'Wants a van for Saturday')) ->> 'ok'))
  || '/' || (select held_by::text from pg_temp.hold('zh_r')), 'true/' || test.id('zh_cs')::text);

-- Create lead from a call
select app.server_phone_event(jsonb_build_object('type', 'call.ringing', 'event_id', 'EVzhn', 'call_id', 'ACZHN', 'quo_id', 'ACZHN', 'direction', 'in', 'their_number', '+14165559010', 'at', now()));
create temp table zh_cl as select pg_temp.dr('zh_cs', 'va_do', 'phone_create_lead', jsonb_build_object('id', (select id from phone_threads where number = '+14165559010'), 'name', 'Una Zh')) r;
select test.eq('Create lead from a call: held by the creator', (select held_by::text from lead_holds where lead_id = ((select r ->> 'lead_id' from zh_cl))::uuid), test.id('zh_cs')::text);

-- ---------------------------------------------------------------- 6. never for someone not onboarded, or an Admin
update staff_profiles set onboarding_exempt = false where user_id = test.id('zh_new');
update program_settings set staff_onboarding_gate = true;
select test.eq('precondition: the new hire is not fully onboarded', app.staff_fully_onboarded(test.id('zh_new')), false);
select pg_temp.lead('i', '+14165559011');
select pg_temp.call('ACZH10', '+14165559011', 'USZHNEW');
select test.eq('not onboarded: a call answered holds nothing', (select count(*) from lead_holds where lead_id = test.id('lead:zhi')), 0::bigint);
select test.ok('not onboarded: the take is refused', app.lead_hold_take(test.id('zh_new'), test.id('lead:zhi')) is null);
select test.throws('not onboarded: not even straight into the table',
  format($$insert into lead_holds (lead_id, held_by, role, expires_at) values (%L, %L, 'cs', now() + interval '1 hour')$$, test.id('lead:zhi'), test.id('zh_new')), 'has not finished onboarding');
-- a hold whose holder stops being onboarded ends at the next read
select pg_temp.lead('j', '+14165559012');
select pg_temp.call('ACZH11', '+14165559012', 'USZHCS1');
update program_settings set staff_onboarding_gate = false;
insert into lead_holds (lead_id, held_by, role, expires_at) values (test.id('lead:zhi'), test.id('zh_new'), 'cs', now() + interval '1 hour');
update program_settings set staff_onboarding_gate = true;
select app.sl_expire();
select test.eq('a holder no longer onboarded: the hold ends', (select count(*) from lead_holds where lead_id = test.id('lead:zhi')), 0::bigint);
update program_settings set staff_onboarding_gate = false;
select pg_temp.lead('k', '+14165559013');
select app.lead_hold_take(test.id('zh_admin'), test.id('lead:zhk'));
select test.eq('an Admin never takes a hold', (select count(*) from lead_holds where lead_id = test.id('lead:zhk')), 0::bigint);
select test.ok('Sales alone never take one', app.lead_hold_take(test.id('zh_sales'), test.id('lead:zhk')) is null);

-- ---------------------------------------------------------------- 7. an Admin releases early
select pg_temp.lead('l', '+14165559014', 'zh_sales2');
select pg_temp.call('ACZH12', '+14165559014', 'USZHCS1');
select test.throws('release: Sales cannot', format($$select pg_temp.dr('zh_sales', 'va_do', 'lead_hold_release', jsonb_build_object('lead', %L))$$, test.id('lead:zhl')), 'Only');
select test.eq('release: an Admin releases it, the lead returns to who brought it',
  (pg_temp.dr('zh_admin', 'admin_do', 'lead_hold_release', jsonb_build_object('lead', test.id('lead:zhl'))) ->> 'returned_to'), test.id('zh_sales2')::text);
select test.eq('release: no hold left, ended by the Admin in the log', (select count(*) from lead_holds where lead_id = test.id('lead:zhl'))::text || '/' ||
  (select by_user::text from lead_claim_log where lead_id = test.id('lead:zhl') and action = 'hold_end'), '0/' || test.id('zh_admin')::text);
select pg_temp.lead('m', '+14165559015');
select pg_temp.call('ACZH13', '+14165559015', 'USZHCS1');
select test.lives('release: the holder may release their own', format($$select pg_temp.dr('zh_cs', 'va_do', 'lead_hold_release', jsonb_build_object('lead', %L))$$, test.id('lead:zhm')));
select test.eq('release: and it is in the pool', (select count(*) from lead_holds where lead_id = test.id('lead:zhm')) || '/' || (select count(*) from lead_claims where lead_id = test.id('lead:zhm')), '0/0');
-- an Admin's reassign supersedes a hold
select pg_temp.lead('n', '+14165559016');
select pg_temp.call('ACZH14', '+14165559016', 'USZHCS1');
select pg_temp.dr('zh_admin', 'admin_do', 'lead_reassign', jsonb_build_object('lead', test.id('lead:zhn'), 'to', test.id('zh_sales')));
select test.eq('reassign by an Admin: the hold ends, the person has it', (select count(*) from lead_holds where lead_id = test.id('lead:zhn'))::text || '/' || (select claimed_by::text from lead_claims where lead_id = test.id('lead:zhn')), '0/' || test.id('zh_sales')::text);

-- ---------------------------------------------------------------- 8. the hold is not a claim: no credit, closed leads release it
select pg_temp.lead('o', '+14165559017');
select pg_temp.call('ACZH15', '+14165559017', 'USZHCS1');
select test.eq('credit: customer service has no claim or reassign in the log (what a booking''s credit reads)',
  (select count(*) from lead_claim_log where lead_id = test.id('lead:zho') and user_id = test.id('zh_cs') and action in ('claim', 'reassign')), 0::bigint);
select test.eq('credit: a returned lead is never credited to the holder (previous owner skips cs)', app.lead_previous_owner(test.id('lead:zho')), null::uuid);
select pg_temp.dr('zh_admin', 'admin_do', 'lead_outcome', jsonb_build_object('lead', test.id('lead:zho'), 'outcome', 'won'));
select test.eq('a lead won ends the hold, nobody gets it back', (select count(*) from lead_holds where lead_id = test.id('lead:zho')) || '/' || (select count(*) from lead_claims where lead_id = test.id('lead:zho')), '0/0');
select test.ok('the outcome is not credited to customer service', (select sales_outcome_by is distinct from test.id('zh_cs') from leads where id = test.id('lead:zho')));

-- privileges: the server only
select test.ok('privileges: the hold functions are not callable by the signed-in role', not has_function_privilege('authenticated', 'app.lead_hold_take(uuid, uuid)', 'execute')
  and not has_function_privilege('authenticated', 'app.lead_hold_end(uuid, uuid, text, boolean, timestamptz)', 'execute') and has_function_privilege('service_role', 'app.lead_hold_release(uuid, jsonb)', 'execute'));
select test.ok('privileges: the wrapped functions keep their callers', has_function_privilege('service_role', 'app.sl_expire(timestamptz)', 'execute')
  and has_function_privilege('service_role', 'app.renter_note_add(uuid, jsonb)', 'execute') and has_function_privilege('service_role', 'app.sl_row(leads, uuid)', 'execute'));
