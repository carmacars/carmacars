-- 99: the townhall deck's new sections (migration 4600): website visitors, the top incident (automatic, an Admin's pick), disputes
-- and chargebacks, birthdays (the optional month and day on the staff profile), the KPIs every staff member hit, the fleet's cars
-- by name, the 30-minute run, and townhall_status counting the KPI slide. Fixtures start with "th6".
select test.suite('99 r50 townhall deck: more sections');
select test.mk_user('th6_admin', 'admin');
select test.mk_user('th6_cs', 'va', 'cs');
select test.mk_user('th6_field', 'field');
select test.mk_owner('th6_own');
select test.mk_vehicle('th6_car', 'th6_own');
select test.mk_vehicle('th6_old', 'th6_own');
update vehicles set retired_at = now() where id = test.id('vehicle:th6_old');
create temp table th6_w as select (date_trunc('week', app.today()::timestamp))::date w;
create function test.th6_slide(p_key text) returns jsonb language sql as $$
  select s from townhall_decks d, jsonb_array_elements(d.slides) s where d.week_of = (select w from th6_w) and s ->> 'key' = p_key $$;
create function test.th6_point(p_key text, p_label text) returns text language sql as $$
  select p ->> 'value' from jsonb_array_elements(test.th6_slide(p_key) -> 'points') p where p ->> 'label' = p_label $$;
create temp table th6_v as select app.townhall_visitors_avg((select w from th6_w), (select w from th6_w) + 7) before;

-- the week's data
insert into visitor_sessions (id, visitor_id, started_at) select gen_random_uuid(), gen_random_uuid(), now() - interval '1 minute' from generate_series(1, 7);
insert into tracker_alerts (kind, vehicle_id, at, speed_kmh, title, dedupe_key) values
  ('speeding', test.id('vehicle:th6_car'), ((select w from th6_w) - 27)::timestamp at time zone 'America/Toronto', 150, 'Speeding', 'th6:speed'),
  ('pound', test.id('vehicle:th6_car'), now() - interval '3 minutes', null, 'At a pound', 'th6:pound');
insert into disputes (payment_id, amount_cents, status, opened_at, processor_dispute_ref)
select (select id from payments order by created_at limit 1), 12345, st, now() - interval '1 minute', 'dp_th6_' || st from unnest(array['open', 'won']) st
 where exists (select 1 from payments);
select app.door(test.id('th6_cs'), 'aal1', 'ops_do', 'staff_birthday_save',
  jsonb_build_object('month', extract(month from app.local_date(app.townhall_next(now()))), 'day', extract(day from app.local_date(app.townhall_next(now())))));
insert into academy_attempts (user_id, section_id, correct, total, score_bps, passed)
select test.id('th6_cs'), id, 5, 5, 10000, true from academy_sections a order by a.id limit 1;
select app.townhall_build((select w from th6_w), test.id('th6_admin'));

-- ================================================================ 1. visitors
select test.ok('visitors: the slide follows the funnel', (select o from townhall_decks d, jsonb_array_elements(d.slides) with ordinality t(s, o) where d.week_of = (select w from th6_w) and s ->> 'key' = 'visitors')
  = 1 + (select o from townhall_decks d, jsonb_array_elements(d.slides) with ordinality t(s, o) where d.week_of = (select w from th6_w) and s ->> 'key' = 'funnel'));
select test.ok('visitors: today''s 7 new visitors raise the average a day', test.th6_point('visitors', 'Visitors a day this week')::numeric > (select coalesce(before, 0) from th6_v));
select test.ok('visitors: last week, the change and the 4-week trend are given', test.th6_point('visitors', 'Last week') is not null
  and test.th6_point('visitors', 'On last week') ~ '^(up|down|flat|no data)' and test.th6_point('visitors', '4-week trend') ~ '^(up|down|flat|no data)');
select test.eq('visitors: the change in words', app.th_change(110, 100) || '/' || app.th_change(90, 100) || '/' || app.th_change(5, 0) || '/' || app.th_change(3, 3), 'up 10%/down 10%/up (nothing before)/flat');

-- ================================================================ 2. the top incident
select test.ok('incident: the pound outranks the speeding', test.th6_slide('incident') #>> '{lines,0}' like app.vehicle_name(test.id('vehicle:th6_car')) || ': the tracker shows the car at a pound%');
select test.eq('incident: picked automatically, with the candidates', (test.th6_slide('incident') ->> 'picked') || '/' || (jsonb_array_length(test.th6_slide('incident') -> 'candidates') >= 2), 'automatic/true');
select test.ok('incident: a speeding alert is a candidate, with the speed', app.townhall_incident_candidates((select w from th6_w) - 28)::text like '%driven at 150 km/h%');
select test.ok('incident: no renter is named', not exists (select 1 from jsonb_array_elements(test.th6_slide('incident') -> 'candidates') c, renters r where c ->> 'label' like '%' || r.legal_name || '%'));
select test.throws('incident: only an Admin picks', format($q$select app.door(%L, 'aal1', 'ops_do', 'townhall_incident_pick', jsonb_build_object('deck', (select id from townhall_decks where week_of = (select w from th6_w)), 'body', 'Something else'))$q$, test.id('th6_cs')));
select test.throws('incident: a ref that is not a candidate is refused', format($q$select app.door(%L, 'aal1', 'admin_do', 'townhall_incident_pick', jsonb_build_object('deck', (select id from townhall_decks where week_of = (select w from th6_w)), 'ref', 'claim:' || gen_random_uuid()))$q$, test.id('th6_admin')), 'Choose one%');
select app.door(test.id('th6_admin'), 'aal1', 'admin_do', 'townhall_incident_pick', jsonb_build_object('deck', (select id from townhall_decks where week_of = (select w from th6_w)),
  'ref', test.th6_slide('incident') #>> '{candidates,1,ref}'));
select test.eq('incident: an Admin picks another candidate; the deck is rebuilt with it', (test.th6_slide('incident') ->> 'picked') || '/' || (test.th6_slide('incident') #>> '{lines,0}' = test.th6_slide('incident') #>> '{candidates,1,label}'), 'admin/true');
select app.door(test.id('th6_admin'), 'aal1', 'admin_do', 'townhall_incident_pick', jsonb_build_object('deck', (select id from townhall_decks where week_of = (select w from th6_w)), 'body', 'A delivery in a snowstorm'));
select test.eq('incident: or describes it', test.th6_slide('incident') #>> '{lines,0}', 'A delivery in a snowstorm');
select app.door(test.id('th6_admin'), 'aal1', 'admin_do', 'townhall_incident_pick', jsonb_build_object('deck', (select id from townhall_decks where week_of = (select w from th6_w))));
select test.eq('incident: both empty goes back to automatic', test.th6_slide('incident') ->> 'picked', 'automatic');

-- ================================================================ 3. disputes and chargebacks
select test.eq('disputes: this week''s count, open against won and lost, from the disputes table', test.th6_point('disputes', 'This week'),
  (select format('%s (%s open, %s won, %s lost)', count(*), count(*) filter (where status in ('open', 'evidence_submitted')), count(*) filter (where status = 'won'), count(*) filter (where status = 'lost'))
     from disputes where opened_at >= (select w from th6_w)::timestamp at time zone 'America/Toronto' and opened_at < ((select w from th6_w) + 7)::timestamp at time zone 'America/Toronto'));
select test.ok('disputes: the fixtures are counted', not exists (select 1 from payments) or test.th6_point('disputes', 'This week') !~ '^0 ');
select test.ok('disputes: the month to date is given', test.th6_point('disputes', 'Month to date') ~ '^\d+ \(\d+ open, \d+ won, \d+ lost\)$');
select test.eq('disputes: the amounts are on an Admin-only slide', (test.th6_slide('disputes') ->> 'admin_only') || '/' || (test.th6_slide('disputemoney') ->> 'admin_only'), 'false/true');
select test.ok('disputes: no customer is named', not exists (select 1 from renters r where (test.th6_slide('disputes')::text || test.th6_slide('disputemoney')::text) like '%' || r.legal_name || '%'));

-- ================================================================ 4. birthdays
select test.eq('birthdays: the staff member saved theirs (month and day)', (select birthday_month || '-' || birthday_day from staff_profiles where user_id = test.id('th6_cs')),
  extract(month from app.local_date(app.townhall_next(now()))) || '-' || extract(day from app.local_date(app.townhall_next(now()))));
select test.ok('birthdays: the slide shows it in the townhall''s week', (test.th6_slide('birthdays') -> 'lines')::text like '%Th6 Cs: %(this week)%');
select test.throws('birthdays: a day the month has not is refused', format($q$select app.door(%L, 'aal1', 'ops_do', 'staff_birthday_save', '{"month": 4, "day": 31}')$q$, test.id('th6_field')), 'That day%');
select test.throws('birthdays: a staff member cannot set someone else''s', format($q$select app.door(%L, 'aal1', 'ops_do', 'staff_birthday_save', jsonb_build_object('user_id', %L, 'month', 1, 'day', 2))$q$, test.id('th6_cs'), test.id('th6_field')));
select app.door(test.id('th6_admin'), 'aal1', 'admin_do', 'staff_birthday_save', jsonb_build_object('user_id', test.id('th6_field'), 'month', 2, 'day', 29));
select test.eq('birthdays: an Admin sets one; the staff list shows it', app.staff_access_facts(test.id('th6_admin'), '{}') #>> array[test.id('th6_field')::text, 'birthday'], '02-29');
select test.eq('birthdays: the staff member reads theirs', app.door(test.id('th6_field'), 'aal1', 'field_read', 'staff_birthday', '{}') ->> 'day', '29');
select test.eq('birthdays: February 29 is February 28 in other years', app.birthday_on(2027, 2, 29), date '2027-02-28');
select app.door(test.id('th6_admin'), 'aal1', 'admin_do', 'staff_birthday_save', jsonb_build_object('user_id', test.id('th6_field'), 'month', '', 'day', ''));
select test.eq('birthdays: cleared', (select birthday_month from staff_profiles where user_id = test.id('th6_field')), null::smallint);

-- ================================================================ 5. KPIs hit, every staff member
select test.ok('kpis: a line for every real staff member with a tracked KPI (5074, REQ-070)', not exists (select 1 from staff_profiles sp where app.staff_is_member(sp.user_id)
  and exists (select 1 from jsonb_array_elements(app.townhall_staff_kpis((select w from th6_w))) k where k ->> 'user_id' = sp.user_id::text)
  and not exists (select 1 from jsonb_array_elements(test.th6_slide('kpis') -> 'staff') x where x ->> 'user_id' = sp.user_id::text)));
select test.eq('kpis: as many lines as staff', jsonb_array_length(test.th6_slide('kpis') -> 'lines'), jsonb_array_length(test.th6_slide('kpis') -> 'staff'));
select test.ok('kpis: the Academy section passed is a KPI hit', not exists (select 1 from academy_sections)
  or exists (select 1 from jsonb_array_elements_text(test.th6_slide('kpis') -> 'lines') l where l like 'Th6 Cs: %Academy: 1 section passed%'));
select test.ok('kpis: someone with nothing hit still has a line', exists (select 1 from jsonb_array_elements_text(test.th6_slide('kpis') -> 'lines') l where l like 'Th6 Field: %'));
select test.eq('status: nobody missing from the KPI slide', jsonb_array_length(app.townhall_status(test.id('th6_admin'), '{}') -> 'staff_missing_kpis'), 0);
update townhall_decks set slides = (select jsonb_agg(s order by o) from jsonb_array_elements(slides) with ordinality t(s, o) where s ->> 'key' <> 'people') where week_of = (select w from th6_w);
select test.eq('status: the KPI slide counts as featured (the people slide taken out)', app.townhall_status(test.id('th6_admin'), '{}') ->> 'staff_missing_count', '0');
select app.townhall_build((select w from th6_w), test.id('th6_admin'));

-- ================================================================ 6. the fleet by name, 7. socials, the run
select test.ok('fleet: this week''s added cars by name', (test.th6_slide('fleet') -> 'lines')::text like '%Added this week: %' || app.vehicle_name(test.id('vehicle:th6_car')) || '%');
select test.ok('fleet: this week''s removed cars by name', (test.th6_slide('fleet') -> 'lines')::text like '%Removed this week: %' || app.vehicle_name(test.id('vehicle:th6_old')) || '%');
select test.ok('fleet: the counts week by week stay', (test.th6_slide('fleet') -> 'lines')::text like '%added, % removed%');
select test.ok('socials: still the manual slide', test.th6_slide('social') is not null);
select test.eq('the run is 30 minutes', (select sum((s ->> 'minutes')::int) from jsonb_array_elements((select slides from townhall_decks where week_of = (select w from th6_w))) s), 30::bigint);
select test.ok('every slide has its minutes', not exists (select 1 from jsonb_array_elements((select slides from townhall_decks where week_of = (select w from th6_w))) s where s -> 'minutes' is null));

-- ================================================================ privileges
select test.ok('the new functions are not open to the public', not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'app' and p.proname in ('staff_birthday_save', 'townhall_incident_pick', 'townhall_incident_candidates', 'townhall_staff_kpis', 'townhall_slides_4600', 'door_pre4600')
    and has_function_privilege('authenticated', p.oid, 'execute')));
select test.ok('the new functions end their search_path with pg_temp', not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'app' and p.proname in ('staff_birthday_save', 'staff_birthday_read', 'townhall_incident_pick', 'townhall_incident_candidates', 'townhall_staff_kpis', 'townhall_slides_4600', 'townhall_visitor_slide', 'townhall_dispute_slides', 'townhall_birthday_lines')
    and not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%pg_temp')));
