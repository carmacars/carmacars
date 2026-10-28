-- 99: careers and hiring (migration 0173, docs/changes/2026-10-26-careers-hiring.md).
-- Roles with screening questions scored on the server (points and knock-outs never reach a browser), the application with its
-- outcome (invited, declined, below the bar, referred to another role), the booking link (book, move, cancel; one candidate a
-- slot even when two book at once), reminders and the text, the interview rubric with the final score and the rank per role,
-- hire (the staff invitation recorded), the Admin-only reads, the removal of personal data after 12 months, and the privileges.
-- Fixtures start with "hir".
select test.suite('99 careers and hiring');

select test.mk_user('hir_admin', 'admin');
select test.mk_user('hir_cs', 'va', 'cs');

create temp table h99 as select null::text as k, null::jsonb as v limit 0;
create or replace function test.h99(p_k text) returns jsonb language sql stable as $$ select v from pg_temp.h99 where k = p_k $$;
create or replace function test.h99a(p_k text) returns job_applications language sql stable as $$
  select * from job_applications where token = test.h99(p_k) ->> 'token' or lower(email) = lower(p_k || '@hir.example.test')
   order by (token = coalesce(test.h99(p_k) ->> 'token', '')) desc, created_at limit 1 $$;
create or replace function test.h99apply(p_k text, p_role text, p_answers jsonb, p_extra jsonb default '{}'::jsonb) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  r := public.server_hiring_apply(jsonb_build_object('role', p_role, 'full_name', initcap(p_k) || ' Tester', 'email', p_k || '@hir.example.test', 'phone', '416-555-01' || lpad((length(p_k) % 100)::text, 2, '0'),
         'answers', p_answers) || p_extra, null);
  insert into pg_temp.h99 values (p_k, r);
  return r;
end $$;
create or replace function test.h99out(p_k text, p_code text) returns notification_outbox language sql stable as $$
  select o.* from notification_outbox o where o.code = p_code and o.to_address = lower(p_k || '@hir.example.test') order by o.created_at desc limit 1 $$;

-- a strong field applicant, and the same with changes
create or replace function test.h99field(p jsonb default '{}'::jsonb) returns jsonb language sql immutable as $$
  select '{"licence":"Yes, a full G","years":"5 years or more","record":"None","days":["Saturday","Sunday","Monday","Tuesday","Wednesday"],
    "hours":"Full time (35 or more)","transport":"My own car","experience":["Delivery driver","Car detailing or car wash"],
    "late":"Message the office at once, keep the renter updated and follow the office''s instructions",
    "dent":"Stay polite, photograph everything, note it in the app and let the office decide",
    "cash":"Count it in front of them, record it in the app right away and give them the receipt","start":"2026-11-02","pay":"20"}'::jsonb || p $$;
create or replace function test.h99va(p jsonb default '{}'::jsonb) returns jsonb language sql immutable as $$
  select jsonb_build_object('schedule', 'Yes, I can work this schedule every week', 'pay', 'Yes, I accept this pay',
    'internet', 'Fiber or cable, 25 Mbps or faster, plus a backup connection', 'speed', '80 down, 40 up', 'backup', 'A generator, inverter or power station',
    'english', 'Fluent: I handle calls on my own every day', 'years', '5 years or more',
    'experience', 'Five years billing North American clients at an accounting firm: invoices, statements, reconciliations and payouts every single day of the week',
    'tools', jsonb_build_array('QuickBooks', 'Stripe'), 'social', jsonb_build_array('Designing posts in Canva'), 'skills', 'Accuracy, spreadsheets, written English',
    'business', 'Rents cars to customers in Toronto',
    'role', 'I will price the charges after each rental, settle the deposits, match tolls to bookings, bill the owners on the fifteenth and build their statements and payouts for the tenth of the month',
    'scenario', 'Change nothing, verify by a phone number we already have and wait for written approval', 'other_jobs', 'No, this would be my only job', 'clients', 'No',
    'school', 'No', 'education', 'College degree', 'career', 'A long-term career, growing with one company', 'canada', 'Maybe', 'start', '2026-11-09') || p
$$;
create or replace function test.h99sales(p jsonb default '{}'::jsonb) returns jsonb language sql immutable as $$
  select '{"years":"3 to 5 years","done":["Phone sales","Used a CRM","Car rental, dealership or automotive"],"commission":"I like being paid for results",
    "in_person":"Yes","days":["Thursday","Friday","Saturday","Sunday"],"hours":"Yes, all of them","languages":["English","Tagalog"],
    "turo":"Ask what matters most to them, then show what is included (delivery, support, coverage options) and offer only the savings our rate sheet allows",
    "discount":"Explain the options we do have (longer rental rates, the non-refundable saving) and ask which works for them",
    "toll":"Listen, show them the toll record, explain the charge, and pass it to the office if they still dispute it",
    "why_local":"A person answers, we deliver, and we fix problems the same day.","expect":"twenty","start":"2026-11-02","hours_week":"25"}'::jsonb || p $$;

-- ================================================================ 1. roles and what the public sees
select test.eq('roles: six seeded, Field staff and Sales open, the four VA roles closed',
  (select string_agg(slug || ':' || active, ',' order by sort_order) from hiring_roles),
  'field-staff:true,sales-in-person:true,sales-remote:true,va-customer-service:false,va-fleet-operations:false,va-finance-billing:false');
select test.eq('roles: pass mark 60 everywhere', (select string_agg(distinct pass_mark::text, ',') from hiring_roles), '60');
select test.eq('roles: the open roles list for the careers page', (select string_agg(x ->> 'slug', ',') from jsonb_array_elements(public.hiring_roles_public()) x), 'field-staff,sales-in-person,sales-remote');
select test.ok('public role: no points, knock-outs, knock-out reasons, scoring rules or call guide reach a browser',
  public.hiring_role_public('field-staff')::text !~ '"(pts|ko|ko_reason|ko_unless_contains|score|call_guide|pass_mark|refer_to)"'
  and public.hiring_role_public('sales-in-person')::text !~ '"(pts|ko|score)"');
select test.ok('public role: the questions and their choices are there', jsonb_array_length(public.hiring_role_public('field-staff') -> 'questions') = 13
  and public.hiring_role_public('field-staff') #>> '{questions,0,choices,0}' = 'Yes, a full G');
select test.ok('public role: a closed role answers nothing', public.hiring_role_public('va-finance-billing') is null);
select test.ok('sales: no right-to-work question in either role; the only in-person knock-out is the place of work',
  public.hiring_role_public('sales-in-person')::text !~* 'legally|right to work|citizen' and public.hiring_role_public('sales-remote')::text !~* 'legally|right to work|citizen'
  and (select string_agg(q ->> 'key', ',') from hiring_roles r, jsonb_array_elements(r.questions) q where r.slug = 'sales-in-person' and q ? 'ko_reason') = 'in_person');
select test.eq('sales: both commission only; in person 10% to 20%, remote 5 points lower on every rate', (select string_agg(pay_text, ' / ' order by sort_order) from hiring_roles where slug like 'sales-%'),
  'Commission only: 10% to 20% of the rental charge of each rental you source / Commission only: 5% to 15% of the rental charge of each rental you source');
select test.ok('sales: the rates by rental days on each page', (select details::text ~ '10% of the rental charge under 50 rental days in the calendar month, 15% from 50 days, 20% from 100 days' from hiring_roles where slug = 'sales-in-person')
  and (select details::text ~ '5% of the rental charge under 50 rental days in the calendar month, 10% from 50 days, 15% from 100 days' and call_guide::text ~ '5% under 50 rental days' from hiring_roles where slug = 'sales-remote'));
select test.eq('sales: the work mode of each role', (select string_agg(slug || ':' || work_mode, ',' order by sort_order) from hiring_roles where work_mode is not null), 'sales-in-person:in_person,sales-remote:remote');
select test.eq('sales: both hired into the Sales function of the assistant portal', (select string_agg(distinct staff_kind || ':' || va_function || ':' || cardinality(cover_functions), ',') from hiring_roles where slug like 'sales-%'), 'va:sales:0');
select test.ok('sales: the remote role states the 20 hours, the 15-minute reply, the 400 touches and the credit rule', (select details::text ~ '20 hours' and details::text ~ '15 minutes'
  and details::text ~ '400 logged touches' and details::text ~ 'walk-ins and partner deals belong to in-person staff' from hiring_roles where slug = 'sales-remote'));
select test.ok('sales: no base pay or bonus anywhere', not exists (select 1 from hiring_roles where slug like 'sales-%' and (details::text ~* 'base wage|bonus' or call_guide::text ~* 'base wage|bonus'
  or exists (select 1 from jsonb_array_elements(questions) q where q ->> 'label' ~* 'base wage|bonus'))));
set role anon;
select test.eq('roles: anonymous visitors cannot read the tables', test.visible('select * from hiring_roles'), -1::bigint);
reset role;

-- the scoring itself (server only)
select test.eq('score: a perfect field applicant is 100', (app.hiring_score((select questions from hiring_roles where slug = 'field-staff'),
  test.h99field('{"days":["Saturday","Sunday","Monday","Tuesday","Wednesday","Thursday","Friday"],"experience":["Delivery driver","Car rental or Turo","Customer service","Car detailing or car wash"]}')) ->> 'pct')::int, 100);
select test.eq('score: days (each day 1 up to 5, plus 5 for Saturday and 5 for Sunday, at most 10)',
  (select (d ->> 'points') from jsonb_array_elements(app.hiring_score((select questions from hiring_roles where slug = 'field-staff'), test.h99field('{"days":["Monday","Saturday"]}')) -> 'detail') d where d ->> 'key' = 'days'), '7');
select test.eq('score: languages (English 5, each other 2 up to 5)',
  (select (d ->> 'points') from jsonb_array_elements(app.hiring_score((select questions from hiring_roles where slug = 'sales-in-person'), test.h99sales('{"languages":["English","French","Arabic","Punjabi"]}')) -> 'detail') d where d ->> 'key' = 'languages'), '10');
select test.eq('score: in person, remote only is the knock-out of the in-person role', jsonb_array_length(app.hiring_score((select questions from hiring_roles where slug = 'sales-in-person'), test.h99sales('{"in_person":"No, only remotely"}')) -> 'knockouts'), 1);
select test.eq('score: an answer that is not a choice is refused', app.hiring_score((select questions from hiring_roles where slug = 'field-staff'), test.h99field('{"licence":"Maybe"}')) #>> '{errors,licence}', 'Choose one of the answers.');
select test.eq('score: a VA who refuses the schedule or the pay is knocked out', jsonb_array_length(app.hiring_score((select questions from hiring_roles where slug = 'va-finance-billing'),
  test.h99va('{"schedule":"No","pay":"No"}')) -> 'knockouts'), 2);
select test.eq('score: a VA who accepts both passes the bar with no knock-out', (select (s -> 'knockouts')::text || '/' || ((s ->> 'pct')::int >= 60) from (
  select app.hiring_score((select questions from hiring_roles where slug = 'va-finance-billing'), test.h99va()) s) x), '[]/true');
select test.eq('score: moving to Canada is asked, never scored', (select d ->> 'max' from jsonb_array_elements(app.hiring_score((select questions from hiring_roles where slug = 'va-customer-service'),
  test.h99va()) -> 'detail') d where d ->> 'key' = 'canada'), '0');
select test.eq('score: the remote sales check wants words, not figures', (select string_agg(d ->> 'points', '/') from (
  select d from jsonb_array_elements(app.hiring_score((select questions from hiring_roles where slug = 'sales-remote'), '{"post_check":"twelve"}'::jsonb) -> 'detail') d where d ->> 'key' = 'post_check'
  union all select d from jsonb_array_elements(app.hiring_score((select questions from hiring_roles where slug = 'sales-remote'), '{"post_check":"12"}'::jsonb) -> 'detail') d where d ->> 'key' = 'post_check') x), '10/0');

-- ================================================================ 2. applying
select test.ok('apply: not callable by the public (the server only, after Turnstile)', not has_function_privilege('anon', 'public.server_hiring_apply(jsonb, text)', 'execute')
  and not has_function_privilege('authenticated', 'public.server_hiring_apply(jsonb, text)', 'execute'));
select test.eq('apply: missing answers come back by field, nothing saved',
  (public.server_hiring_apply('{"role":"field-staff","full_name":"Hir Empty","email":"empty@hir.example.test","phone":"4165550100","answers":{}}', null) #>> '{errors,licence}'), 'Choose one.');
select test.eq('apply: nothing saved for an invalid form', (select count(*) from job_applications where email = 'empty@hir.example.test'), 0::bigint);
select test.eq('apply: a closed role refuses', public.server_hiring_apply('{"role":"va-fleet-operations"}', null) ->> 'error', 'closed');

-- an interview day three days ahead, for every role (the Admin's door)
insert into h99 select 'day', app.door(test.id('hir_admin'), 'aal2', 'admin_do', 'hiring_day_save', jsonb_build_object('day', app.today() + 3, 'start_time', '09:00', 'end_time', '10:00', 'mode', 'phone'));
select test.eq('day: 9:00 to 10:00, 15-minute slots with 5 minutes between: 3 slots', (test.h99('day') ->> 'slots')::int, 3);
select test.eq('day: slots start 9:00, 9:20, 9:40 Toronto time', (select string_agg(to_char(starts_at at time zone 'America/Toronto', 'HH24:MI'), ',' order by starts_at) from interview_slots where day_id = (test.h99('day') ->> 'id')::uuid), '09:00,09:20,09:40');
create or replace function test.h99slot(p_n integer, p_day text default 'day') returns uuid language sql stable as $$
  select id from interview_slots where day_id = (test.h99(p_day) ->> 'id')::uuid order by starts_at offset p_n - 1 limit 1 $$;

select test.h99apply('hirana', 'field-staff', test.h99field(), '{"source":"indeed","utm":{"utm_source":"indeed","utm_campaign":"field-oct","x":"dropped"}}');
select test.eq('pass: invited, with a booking token', test.h99('hirana') ->> 'outcome', 'invited');
select test.eq('pass: score, source and campaign kept (unknown keys dropped)', (select score || '/' || source || '/' || (utm ->> 'utm_campaign') || '/' || (utm ? 'x') from test.h99a('hirana')), '96/indeed/field-oct/false');
select test.ok('pass: the breakdown has every question with its points', (select jsonb_array_length(score_detail) = 13 and score_points = 101 and score_max = 105 from test.h99a('hirana')));
select app.process_events();
select test.eq('pass: the invitation is queued to the candidate', (test.h99out('hirana', 'applicant_invited')).status, 'queued');
select test.ok('pass: the invitation carries the personal booking link and the call day', (test.h99out('hirana', 'applicant_invited')).payload ->> 'booking_url' like '%/careers/book/' || (test.h99a('hirana')).token
  and (test.h99out('hirana', 'applicant_invited')).payload ->> 'call_days' <> '' and (test.h99out('hirana', 'applicant_invited')).missing_variables = '{}');
select test.eq('pass: applying again is answered the same, nothing new', (select (test.h99apply('hirana', 'field-staff', test.h99field()) ->> 'repeat') || '/' || count(*) from job_applications where email = 'hirana@hir.example.test'), 'true/1');

-- Field knock-out: the referral to Sales, with the reason named gently and the details carried over
select test.h99apply('hirbo', 'field-staff', test.h99field('{"licence":"G2"}'));
select test.eq('field knock-out: referred to Sales (no plain decline)', (select status || '/' || (select slug from hiring_roles where id = referred_role_id) from test.h99a('hirbo')), 'referred/sales-in-person');
select app.process_events();
select test.ok('field knock-out: the referral email names the licence and links the Sales form with the token', (test.h99out('hirbo', 'applicant_referred')).payload ->> 'reason_text' = 'This role needs a full Ontario G licence'
  and (test.h99out('hirbo', 'applicant_referred')).payload ->> 'apply_url' like '%/careers/sales-in-person/apply?ref=' || (test.h99a('hirbo')).token || '&src=referral');
select test.ok('field knock-out: no decline email', (test.h99out('hirbo', 'applicant_declined')).id is null);
select test.ok('field knock-out: remote sales named as the other choice', (test.h99out('hirbo', 'applicant_referred')).payload ->> 'alt_apply_url' like '%/careers/sales-remote/apply?src=referral'
  and (test.h99out('hirbo', 'applicant_referred')).payload ->> 'alt_role_title' like 'Remote Sales%');
select test.eq('referral: the Sales form fills in the name, email and phone', public.server_hiring_prefill((test.h99a('hirbo')).token, 'sales-in-person') ->> 'email', 'hirbo@hir.example.test');
select test.ok('referral: the token fills in nothing for another role', public.server_hiring_prefill((test.h99a('hirbo')).token, 'field-staff') is null);
insert into h99 select 'hirbo_sales', public.server_hiring_apply(jsonb_build_object('role', 'sales-in-person', 'full_name', 'Hirbo Tester', 'email', 'hirbo@hir.example.test', 'phone', '4165550105',
  'answers', test.h99sales(), 'ref', (test.h99a('hirbo')).token, 'source', 'direct'), null);
select test.eq('referral: the Sales application keeps the role''s work mode for the staff invitation', (select work_mode from job_applications where email = 'hirbo@hir.example.test' and role_id = (select id from hiring_roles where slug = 'sales-in-person')), 'in_person');
select test.eq('referral: the Sales application is linked to the Field one, source referral',
  (select source || '/' || (referred_from = (select id from job_applications where email = 'hirbo@hir.example.test' and status = 'referred')) from job_applications where email = 'hirbo@hir.example.test' and role_id = (select id from hiring_roles where slug = 'sales-in-person')),
  'referral/true');
select test.ok('referral: the Admin sees the link both ways', exists (select 1 from jsonb_array_elements(app.door(test.id('hir_admin'), 'aal2', 'admin_read', 'hiring_application',
  jsonb_build_object('id', (select id from job_applications where email = 'hirbo@hir.example.test' and status = 'referred'))) -> 'linked') x where x ->> 'role_slug' = 'sales-in-person')
  and (app.door(test.id('hir_admin'), 'aal2', 'admin_read', 'hiring_application', jsonb_build_object('id', (select id from job_applications where email = 'hirbo@hir.example.test' and status = 'referred'))) #>> '{application,referral_application}') is not null);

-- Field below the bar (no knock-out): referred too
select test.h99apply('hircy', 'field-staff', test.h99field('{"years":"2 to 4 years","record":"More than that","days":["Monday"],"hours":"Under 15","transport":"Bike or walking","experience":[],
  "late":"Leave and tell them to rebook","dent":"Ignore it to avoid a fight","cash":"Tell them cash is not allowed"}'));
select test.eq('field below the bar: referred to Sales', (test.h99a('hircy')).status, 'referred');
select app.process_events();
select test.eq('field below the bar: the reason is gentle and general', (test.h99out('hircy', 'applicant_referred')).payload ->> 'reason_text', 'Your answers did not match what this role needs right now');

-- Field knock-out after already applying to Sales: no referral, a note; no email
select test.h99apply('hirdee', 'sales-in-person', test.h99sales());
select test.h99apply('hirdee', 'field-staff', test.h99field('{"licence":"No licence"}'));
select test.eq('already applied to Sales: declined without a referral, with a note', (select status || '/' || (note like 'Already applied for Sales%') || '/' || (referred_role_id is null)
  from job_applications where email = 'hirdee@hir.example.test' and role_id = (select id from hiring_roles where slug = 'field-staff')), 'declined/true/true');
select app.process_events();
select test.ok('already applied to Sales: neither a referral nor a decline email', (test.h99out('hirdee', 'applicant_referred')).id is null and (test.h99out('hirdee', 'applicant_declined')).id is null);

-- Sales below the bar: the owner reviews; only the confirmation email
select test.h99apply('hirev', 'sales-in-person', test.h99sales('{"years":"Under 1 year","done":[],"commission":"I only want a fixed wage","days":["Monday"],"hours":"No","languages":["Other"],
  "turo":"Match the Turo price","discount":"Say no and end the chat","toll":"Tell them it is not your problem"}'));
select test.eq('sales in person below the bar: offered remote sales', (select status || '/' || (select slug from hiring_roles where id = referred_role_id) from test.h99a('hirev')), 'referred/sales-remote');
create or replace function test.h99remote(p jsonb default '{}'::jsonb) returns jsonb language sql immutable as $$
  select '{"shift":"No","hours_now":"days","backup":"Neither","years":"Under 1 year","tools_detail":"Sheets","mistake":"none","clients":"No other clients",
    "scenario":"Give the 15% to close the sale","tip":"Accept it if the fee is small","post_check":"5","activity":"No","based":"Lagos, Nigeria","start":"2026-11-09","references":"Two clients"}'::jsonb || p $$;
select test.h99apply('hirfay', 'sales-remote', test.h99remote());
select test.eq('remote sales below the bar, the matching role closed: waits for review', (test.h99a('hirfay')).status, 'below_bar');
select app.process_events();
select test.ok('below the bar: the confirmation only', (test.h99out('hirfay', 'applicant_received')).id is not null and (test.h99out('hirfay', 'applicant_declined')).id is null and (test.h99out('hirfay', 'applicant_invited')).id is null);

-- a VA role: the knock-out declines; below the bar offers the best matching open VA role
select app.door(test.id('hir_admin'), 'aal2', 'admin_do', 'hiring_role_save', '{"slug":"va-finance-billing","active":true}');
select test.eq('role toggle: opening a role dates the posting', (select active || '/' || (posted_on = app.today()) from hiring_roles where slug = 'va-finance-billing'), 'true/true');
select test.h99apply('hirfin', 'va-finance-billing', test.h99va('{"schedule":"No"}'));
select test.eq('VA knock-out (the schedule): referred to Sales (remote) (0179)', (select status || '/' || (select slug from hiring_roles where id = referred_role_id) from test.h99a('hirfin')), 'referred/sales-remote');
select app.process_events();
select test.ok('VA knock-out: the referral email, not a decline', (test.h99out('hirfin', 'applicant_referred')).id is not null and (test.h99out('hirfin', 'applicant_declined')).id is null);
select test.h99apply('hirfin2', 'va-finance-billing', test.h99va('{"internet":"Slower than 25 Mbps, or mobile data only","english":"Basic: I am more comfortable in writing","years":"Under 1 year",
  "experience":"none","role":"billing","business":"Sells used cars","career":"A job for now","other_jobs":"Yes, during these hours","tools":[],"social":[],"scenario":"Update the details and pay on time"}'));
select test.eq('VA below the bar: referred to Sales (remote)', (select status || '/' || (select slug from hiring_roles where id = referred_role_id) from test.h99a('hirfin2')), 'referred/sales-remote');
update hiring_roles set active = false where slug = 'sales-remote';
select test.h99apply('hirfin3', 'va-finance-billing', test.h99va('{"schedule":"No"}'));
select test.eq('VA knock-out, Sales (remote) closed: declined with the reason', (select status || '/' || array_to_string(ko_reasons, ',') from test.h99a('hirfin3')), 'declined/the schedule of the role');
update hiring_roles set active = true where slug = 'sales-remote';
select app.door(test.id('hir_admin'), 'aal2', 'admin_do', 'hiring_role_save', '{"slug":"va-finance-billing","active":false}');

-- ================================================================ 3. booking
select test.ok('booking: the server functions are not callable by the public', not has_function_privilege('anon', 'public.server_hiring_book(text, uuid)', 'execute')
  and not has_function_privilege('anon', 'public.server_hiring_booking(text)', 'execute') and not has_function_privilege('anon', 'public.server_hiring_cancel(text)', 'execute'));
select test.ok('booking page: the open slots of the role, Toronto time', (select count(*) >= 3 from jsonb_array_elements(public.server_hiring_booking((test.h99a('hirana')).token) -> 'slots') x
  where (x ->> 'id')::uuid in (test.h99slot(1), test.h99slot(2), test.h99slot(3))));
select test.ok('booking page: an unknown token shows nothing', (public.server_hiring_booking(repeat('0', 64)) ->> 'ok')::boolean = false);
select test.eq('booking page: a referred candidate cannot book their first role', (public.server_hiring_booking((test.h99a('hirbo')).token) ->> 'can_book'), 'false');
select test.eq('book: a slot', public.server_hiring_book((test.h99a('hirana')).token, test.h99slot(1)) ->> 'ok', 'true');
select test.eq('book: status booked, the slot kept', (select status || '/' || (slot_id = test.h99slot(1)) || '/' || booking_seq from test.h99a('hirana')), 'booked/true/1');
-- a second candidate takes the remaining place of another slot; a third tries the full one
select test.h99apply('hirgus', 'field-staff', test.h99field());
select test.eq('book: a full slot is refused', public.server_hiring_book((test.h99a('hirgus')).token, test.h99slot(1)) ->> 'error', 'taken');
select test.ok('booking page: the full slot is not offered to another candidate', not exists (select 1 from jsonb_array_elements(public.server_hiring_booking((test.h99a('hirgus')).token) -> 'slots') x where (x ->> 'id')::uuid = test.h99slot(1)));
select test.eq('book: a referred candidate cannot book', public.server_hiring_book((test.h99a('hirbo')).token, test.h99slot(2)) ->> 'error', 'not_open');
select app.process_events();
select test.ok('book: the confirmation, by phone, with the manage link', (test.h99out('hirana', 'applicant_booked')).payload ->> 'call_when' <> '' and ((test.h99out('hirana', 'applicant_booked')).payload ->> 'is_video')::boolean = false
  and (test.h99out('hirana', 'applicant_booked')).payload ->> 'manage_url' like '%/careers/book/%' and (test.h99out('hirana', 'applicant_booked')).missing_variables = '{}');
select test.eq('move: to another slot', public.server_hiring_book((test.h99a('hirana')).token, test.h99slot(2)) ->> 'moved', 'true');
select test.eq('move: the first slot is free again (another candidate takes it)', public.server_hiring_book((test.h99a('hirgus')).token, test.h99slot(1)) ->> 'ok', 'true');
select app.process_events();
select test.eq('move: a new confirmation, marked as moved', (select count(*) || '/' || bool_or((payload ->> 'rescheduled')::boolean) from notification_outbox where code = 'applicant_booked' and to_address = 'hirana@hir.example.test'), '2/true');
select test.eq('cancel: from the link', public.server_hiring_cancel((test.h99a('hirgus')).token) ->> 'ok', 'true');
select test.eq('cancel: back to invited, the slot freed', (select status || '/' || (slot_id is null) from test.h99a('hirgus')), 'invited/true');
select test.eq('cancel: twice is refused', public.server_hiring_cancel((test.h99a('hirgus')).token) ->> 'error', 'not_booked');
select app.process_events();
select test.ok('cancel: the email with the link to book again', (test.h99out('hirgus', 'applicant_cancelled')).payload ->> 'booking_url' like '%/careers/book/%');

-- two candidates book the last place at the same moment: the slot row is locked, one wins (dblink, where available)
create or replace function pg_temp.race() returns text language plpgsql as $$
declare
  c text := format('host=%s port=%s dbname=%s user=%s', split_part(current_setting('unix_socket_directories'), ',', 1), current_setting('port'), current_database(), current_user);
  a text; b text;
begin
  begin
    create extension if not exists dblink with schema test;
  exception when others then return 'skipped';
  end;
  begin
    perform test.dblink_connect('hir1', c); perform test.dblink_connect('hir2', c);
  exception when others then drop extension if exists dblink; return 'skipped';
  end;
  perform test.dblink_exec('hir1', 'begin');
  select x into a from test.dblink('hir1', format('select public.server_hiring_book(%L, %L) ->> ''ok''', (test.h99a('hirgus')).token, test.h99slot(3))) as t(x text);
  perform test.dblink_send_query('hir2', format('select public.server_hiring_book(%L, %L) ->> ''error''', (test.h99a('hirhal')).token, test.h99slot(3)));
  perform pg_sleep(0.3);
  perform test.dblink_exec('hir1', 'commit');
  select x into b from test.dblink_get_result('hir2') as t(x text);
  perform test.dblink_disconnect('hir1'); perform test.dblink_disconnect('hir2');
  drop extension if exists dblink;
  return a || '/' || b;
end $$;
select test.h99apply('hirhal', 'field-staff', test.h99field());
insert into h99 select 'race', to_jsonb(pg_temp.race());
select test.ok('race: the first booking wins, the second is told the slot is taken (or dblink is not installed)', test.h99('race') #>> '{}' in ('true/taken', 'skipped'));
select test.ok('race: never two candidates in a one-place slot', (select count(*) <= 1 from job_applications where slot_id = test.h99slot(3) and status = 'booked'));

-- ================================================================ 4. reminders and the text
select test.eq('reminder: the evening before at 6 pm Toronto time', (app.job_hiring(app.local_midnight(app.today() + 2) + interval '18 hours 5 minutes') ->> 'evening')::int >= 1, true);
select test.ok('reminder: marked so it goes once', (test.h99a('hirana')).reminded_evening_at is not null
  and (app.job_hiring(app.local_midnight(app.today() + 2) + interval '18 hours 20 minutes') ->> 'evening')::int = 0);
update program_settings set phone_enabled = true, hiring_sms_reminders = true;
select test.ok('reminder: an hour before', (app.job_hiring((select starts_at from interview_slots where id = test.h99slot(2)) - interval '50 minutes') ->> 'hour')::int >= 1);
select app.process_events();
select test.eq('reminder: two emails (tomorrow, in about an hour)', (select string_agg(payload ->> 'when_text', ',' order by created_at) from notification_outbox where code = 'applicant_reminder' and to_address = 'hirana@hir.example.test'), 'tomorrow,in about an hour');
select test.ok('reminder: a text to the candidate an hour before', exists (select 1 from phone_outbox where dedupe_key like 'hiring_reminder:' || (test.h99a('hirana')).id || ':%' and body like 'CarmaCars: your interview call%'));

-- ================================================================ 5. the rubric, the score and the rank
select test.throws('rubric: a browser session cannot call it', format($$set local role authenticated; select app.hiring_score_save(%L, '{}')$$, test.id('hir_admin')), 'permission denied');
select test.throws('rubric: an assistant cannot use the door', format($$select app.door(%L, 'aal2', 'admin_do', 'hiring_score', jsonb_build_object('id', %L))$$, test.id('hir_cs'), (test.h99a('hirana')).id), 'Admin');
select test.throws('rubric: scores are 1 to 5', format($$select app.door(%L, 'aal2', 'admin_do', 'hiring_score', jsonb_build_object('id', %L, 'scores', '{"communication": 6}'::jsonb))$$, test.id('hir_admin'), (test.h99a('hirana')).id), '1 to 5');
insert into h99 select 'score_ana', app.door(test.id('hir_admin'), 'aal2', 'admin_do', 'hiring_score', jsonb_build_object('id', (test.h99a('hirana')).id,
  'scores', '{"communication":5,"reliability":4,"role_skills":4,"customer":3,"judgement":5,"attitude":5}'::jsonb, 'notes', 'Strong', 'decision', 'hire'));
-- interview = (5*20 + 4*20 + 4*20 + 3*15 + 5*15 + 5*10) / 5 = 86; final = 96 * 0.4 + 86 * 0.6 = 90.0
select test.eq('rubric: interview score of 100 from the weights, final = 40% screening + 60% interview',
  (select interview_score || '/' || final_score from interview_scores where application_id = (test.h99a('hirana')).id), '86/90.0');
select test.eq('rubric: the call is marked as held', (test.h99a('hirana')).status, 'interviewed');
select test.eq('rank: first in the role', (test.h99('score_ana') ->> 'rank'), '1');
-- a second interviewed candidate with a higher final score takes rank 1
select public.server_hiring_book((test.h99a('hirgus')).token, (select x.id from interview_slots x where x.day_id = (test.h99('day') ->> 'id')::uuid and not exists (select 1 from job_applications a where a.slot_id = x.id and a.status = 'booked') order by x.starts_at limit 1));
select app.door(test.id('hir_admin'), 'aal2', 'admin_do', 'hiring_score', jsonb_build_object('id', (test.h99a('hirgus')).id,
  'scores', '{"communication":5,"reliability":5,"role_skills":5,"customer":5,"judgement":5,"attitude":5}'::jsonb, 'decision', 'hire'));
select test.eq('rank: updates when another candidate scores higher', (select string_agg(x ->> 'full_name' || ':' || (x ->> 'rank'), ',' order by (x ->> 'rank')::int)
  from jsonb_array_elements(app.door(test.id('hir_admin'), 'aal2', 'admin_read', 'hiring_shortlist', '{}') #> '{roles,0,rows}') x), 'Hirgus Tester:1,Hirana Tester:2');
select test.eq('no-show: not ranked', (select (app.door(test.id('hir_admin'), 'aal2', 'admin_do', 'hiring_score', jsonb_build_object('id', (test.h99a('hirhal')).id, 'decision', 'no_show')) ->> 'status')
  || '/' || coalesce((app.door(test.id('hir_admin'), 'aal2', 'admin_read', 'hiring_application', jsonb_build_object('id', (test.h99a('hirhal')).id)) #>> '{application,rank}'), 'none')), 'no_show/none');

-- ================================================================ 6. status changes by the Admin
select test.throws('decline: not after the call', format($$select app.door(%L, 'aal2', 'admin_do', 'hiring_decline', jsonb_build_object('id', %L))$$, test.id('hir_admin'), (test.h99a('hirana')).id), 'Not hired');
select test.eq('invite anyway: a candidate below the bar', app.door(test.id('hir_admin'), 'aal2', 'admin_do', 'hiring_invite', jsonb_build_object('id', (test.h99a('hirev')).id)) ->> 'status', 'invited');
select app.process_events();
select test.eq('invite anyway: the invitation email', (select count(*) from notification_outbox where code = 'applicant_invited' and to_address = 'hirev@hir.example.test'), 1::bigint);
select test.throws('invite anyway: not someone already invited', format($$select app.door(%L, 'aal2', 'admin_do', 'hiring_invite', jsonb_build_object('id', %L))$$, test.id('hir_admin'), (test.h99a('hirev')).id), 'Only a candidate');
select test.eq('decline with the template', app.door(test.id('hir_admin'), 'aal2', 'admin_do', 'hiring_decline', jsonb_build_object('id', (test.h99a('hirev')).id)) ->> 'status', 'declined');
select app.process_events();
select test.ok('decline: the email without a named reason', (test.h99out('hirev', 'applicant_declined')).payload ->> 'decline_reason' = '');
select test.eq('withdrawn', app.door(test.id('hir_admin'), 'aal2', 'admin_do', 'hiring_withdraw', jsonb_build_object('id', (test.h99a('hircy')).id)) ->> 'status', 'withdrawn');
select test.eq('not hired after the call', app.door(test.id('hir_admin'), 'aal2', 'admin_do', 'hiring_reject', jsonb_build_object('id', (test.h99a('hirgus')).id)) ->> 'status', 'rejected');

-- ================================================================ 7. hire: the staff invitation recorded
select test.throws('hire: the staff account comes first', format($$select app.door(%L, 'aal2', 'admin_do', 'hiring_hire', jsonb_build_object('id', %L))$$, test.id('hir_admin'), (test.h99a('hirana')).id), 'Invite the staff account first');
-- the web app's invitation (inviteAccount): the sign-in, then app.admin_invite_account gives the field role
insert into users (id, email, full_name) values (test.id('hir_hired'), 'hirana@hir.example.test', 'Hirana Tester');
select app.admin_invite_account(test.id('hir_admin'), jsonb_build_object('user_id', test.id('hir_hired'), 'email', 'hirana@hir.example.test', 'full_name', 'Hirana Tester', 'role', 'field', 'field_function', 'driver_detailer'));
select test.throws('hire: an account in the wrong portal is refused', format($$select app.door(%L, 'aal2', 'admin_do', 'hiring_hire', jsonb_build_object('id', %L, 'user_id', %L))$$, test.id('hir_admin'), (test.h99a('hirana')).id, test.id('hir_cs')), 'Invite the staff account first');
select test.eq('hire: recorded', app.door(test.id('hir_admin'), 'aal2', 'admin_do', 'hiring_hire', jsonb_build_object('id', (test.h99a('hirana')).id, 'user_id', test.id('hir_hired'))) ->> 'status', 'hired');
select test.ok('hire: with the staff account', (test.h99a('hirana')).hired_user_id = test.id('hir_hired'));
select test.ok('hire: the staff profile exists for the staff agreement', exists (select 1 from staff_profiles where user_id = test.id('hir_hired') and staff_type = 'field'));

-- ================================================================ 8. Admin only
select test.throws('reads: an assistant cannot read the board', format($$select app.door(%L, 'aal2', 'admin_read', 'hiring', '{}')$$, test.id('hir_cs')), 'Admin');
select set_config('request.jwt.claim.sub', test.id('hir_cs')::text, false);
set role authenticated;
select test.eq('rows: an assistant sees no application', test.visible('select * from job_applications'), 0::bigint);
select test.eq('rows: nor any rubric', test.visible('select * from interview_scores'), 0::bigint);
reset role;
select set_config('request.jwt.claim.sub', test.id('hir_admin')::text, false);
set role authenticated;
select test.ok('rows: an Admin sees them', test.visible('select * from job_applications') > 0);
reset role;
select set_config('request.jwt.claim.sub', '', false);
set role anon;
select test.eq('rows: anonymous visitors cannot read applications', test.visible('select * from job_applications'), -1::bigint);
select test.ok('anon: the role page is a public read', public.hiring_role_public('field-staff') is not null);
reset role;
select test.ok('board: filters by role, status and score', (select bool_and(x ->> 'role_slug' = 'field-staff' and (x ->> 'score')::int >= 90)
  from jsonb_array_elements(app.door(test.id('hir_admin'), 'aal2', 'admin_read', 'hiring', '{"role":"field-staff","min_score":"90"}') -> 'applications') x));
select test.ok('the admin functions are not for browser sessions', not has_function_privilege('authenticated', 'app.hiring_hire(uuid, jsonb)', 'execute')
  and not has_function_privilege('anon', 'app.hiring_score(jsonb, jsonb)', 'execute') and not has_function_privilege('authenticated', 'app.job_hiring(timestamptz)', 'execute'));

-- ================================================================ 9. removal after 12 months
update job_applications set decided_at = now() - interval '13 months' where email = 'hirev@hir.example.test';
select test.ok('retention: the job removes the personal data of a candidate not hired after 12 months', (app.job_hiring() ->> 'purged')::int >= 1);
select test.eq('retention: name, contact details and answers gone; the score stays', (select full_name || '/' || coalesce(email, '-') || '/' || coalesce(phone, '-') || '/' || answers::text || '/' || (score is not null)
  from job_applications where purged_at is not null and role_id = (select id from hiring_roles where slug = 'sales-in-person') order by purged_at desc limit 1), 'Removed/-/-/{}/true');
select test.ok('retention: a hired candidate is kept', (test.h99a('hirana')).purged_at is null);
select test.ok('privacy policy: says so', (select body like '%Job applications from people we do not hire%12 months after our decision%' from site_content_blocks where block_key = 'legal.privacy') is not false);

-- ================================================================ 10. the default day of the owner's request
select test.ok('seed: the Thursday, October 29 day (9:00 to 19:00, phone, Field and Sales) exists only while it is ahead',
  case when app.today() < date '2026-10-29' or exists (select 1 from interview_days where day = date '2026-10-29' and note = 'Interview day for the Indeed roles')
       then (select count(*) = 30 and bool_and(d.mode = 'phone') from interview_slots s join interview_days d on d.id = s.day_id where d.day = date '2026-10-29' and d.note = 'Interview day for the Indeed roles')
       else not exists (select 1 from interview_days where day = date '2026-10-29' and note = 'Interview day for the Indeed roles') end);
