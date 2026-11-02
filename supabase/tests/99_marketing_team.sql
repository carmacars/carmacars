-- 99: Sales's Marketing tab (migration 0510): claims per person, car and copy variant, no copy live twice, at most the setting's
-- live listings a car, expiry, the inbox credited to the salesperson; and the "Stuck?" help events. Fixtures start with "mkt".
select test.suite('99 marketing team and stuck help');
select test.mk_user('mkt_admin', 'admin');
select test.mk_user('mkt_s1', 'va', 'sales');
select test.mk_user('mkt_s2', 'va', 'sales');
select test.mk_user('mkt_s3', 'va', 'sales');
select test.mk_user('mkt_s4', 'va', 'sales');
select test.mk_user('mkt_cs', 'va', 'cs');
select test.mk_owner('mkt_own');
insert into vehicles (id, owner_id, year, make, model, trim, colour, plate, vin, class, status, management_mode, onboarding_method, body_type, supply_type, is_sample, odometer_km)
values (test.id('vehicle:MKT1'), test.id('owner:mkt_own'), 2023, 'Toyota', 'Camry', 'SE', 'Grey', 'MKT1AA', 'MKTVIN00000000001', 'standard', 'available', 'managed', 'transfer', 'Sedan', 'company', false, 41000);
insert into rate_cards (vehicle_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, km_allowance_per_day, overage_cents_per_km, deposit_cents, delivery_fee_cents, pickup_fee_cents, effective_from)
values (test.id('vehicle:MKT1'), 8900, 9900, 53400, 178000, 200, 35, 50000, 7500, 7500, now() - interval '1 day');
insert into vehicle_listings (vehicle_id, slug, headline, status, published_at, seats, transmission, body_style)
values (test.id('vehicle:MKT1'), 'mkt-camry', 'x', 'published', now(), 5, 'Automatic', 'Sedan')
on conflict (vehicle_id) do update set status = excluded.status, published_at = now(), slug = excluded.slug;

create function pg_temp.claim(p_user text, p_variant int, p_title text default null, p_cover text default null) returns jsonb language sql as $$
  select public.door(test.id(p_user), 'aal2', 'va_do', 'mp_claim', jsonb_build_object('vehicle', test.id('vehicle:MKT1'), 'variant', p_variant,
    'title', coalesce(p_title, 'Camry variant ' || p_variant || ' by the day'), 'cover', coalesce(p_cover, 'c/' || p_variant || '.jpg'),
    'body', 'Variant ' || p_variant || ' description. Daily and weekly bookings only, not for sale. Book on carmacars.ca.'))
$$;
create function pg_temp.lg(p_user text, p_claim uuid, p_kind text, p_url text default null) returns jsonb language sql as $$
  select public.door(test.id(p_user), 'aal2', 'va_do', 'mp_team_log', jsonb_build_object('claim', p_claim, 'kind', p_kind, 'url', p_url))
$$;

-- the settings and the read
select test.ok('settings: 5 live a car, 30 days, help on after 3 minutes or 3 errors', (select marketplace_max_live_per_car = 5 and marketplace_listing_days = 30 and stuck_help_on
  and stuck_idle_minutes = 3 and stuck_errors = 3 from app.settings()));
select test.ok('Sales read the Marketing tab with the kits', jsonb_array_length(public.door(test.id('mkt_s1'), 'aal2', 'va_read', 'mp_team', '{"_va": "sales"}') -> 'cars') >= 1);
select test.eq('the read carries the limit', (public.door(test.id('mkt_s1'), 'aal2', 'va_read', 'mp_team', '{}') -> 'settings' ->> 'max_live')::int, 5);
select test.throws('customer service has no Marketing tab', format($s$select public.door(%L, 'aal2', 'va_read', 'mp_team', '{}')$s$, test.id('mkt_cs')), 'Sales and Admins');

-- claims: one variant, one person, one copy
create temp table mkt_c as select (pg_temp.claim('mkt_s1', 2) ->> 'id')::uuid as id;
select test.ok('a claim holds the variant for a day', exists (select 1 from marketplace_claims where id = (select id from mkt_c) and status = 'claimed' and variant = 2
  and expires_at between now() + interval '23 hours' and now() + interval '25 hours'));
select test.throws('the same variant by someone else', $$select pg_temp.claim('mkt_s2', 2, 'Another title here')$$, 'already taken');
select test.throws('the same person twice on one car', $$select pg_temp.claim('mkt_s1', 3)$$, 'already have this car');
select test.throws('the same title in another variant', $$select pg_temp.claim('mkt_s2', 3, 'Camry variant 2 by the day')$$, 'already live');
select test.throws('the same cover in another variant', $$select pg_temp.claim('mkt_s2', 3, null, 'c/2.jpg')$$, 'already live');
select test.throws('variant 1 is the owner''s', $$select pg_temp.claim('mkt_s2', 1)$$, 'from 2 to 5');
select test.throws('rent is never written', format($s$select public.door(%L, 'aal2', 'va_do', 'mp_claim', %L)$s$, test.id('mkt_s2'), jsonb_build_object('vehicle', test.id('vehicle:MKT1'),
  'variant', 3, 'title', 'Camry for rent today', 'cover', 'c/9.jpg', 'body', 'Daily and weekly bookings only, not for sale. A long enough description.')), 'never says rent');
select test.throws('"not for sale" is required', format($s$select public.door(%L, 'aal2', 'va_do', 'mp_claim', %L)$s$, test.id('mkt_s2'), jsonb_build_object('vehicle', test.id('vehicle:MKT1'),
  'variant', 3, 'title', 'Camry by the day', 'cover', 'c/9.jpg', 'body', 'Book this Camry by the day on carmacars.ca, delivery across Ontario.')), 'not for sale');

-- posting, renewing, the limit with the owner's own listing
select test.throws('posted needs the listing address', format($s$select pg_temp.lg('mkt_s1', %L, 'posted')$s$, (select id from mkt_c)), 'listing''s address');
select pg_temp.lg('mkt_s1', (select id from mkt_c), 'posted', 'https://www.facebook.com/marketplace/item/2000000000001/');
select test.ok('posted: live until Facebook''s lifetime', exists (select 1 from marketplace_claims where id = (select id from mkt_c) and status = 'live' and posted_on = app.today()
  and expires_at > now() + interval '29 days' and expires_at < now() + interval '32 days'));
select test.ok('logged per person, car and variant', exists (select 1 from marketplace_log where claim_id = (select id from mkt_c) and kind = 'posted' and variant = 2 and logged_by = test.id('mkt_s1')));
select test.throws('someone else cannot log my listing', format($s$select pg_temp.lg('mkt_s2', %L, 'renewed')$s$, (select id from mkt_c)), 'someone else');
select test.eq('my day counts my posts', (public.door(test.id('mkt_s1'), 'aal2', 'va_read', 'mp_team', '{}') ->> 'done_today')::int, 1);
select test.eq('the owner''s day does not count the team''s posts', (public.door(test.id('mkt_admin'), 'aal2', 'admin_read', 'marketplace', '{}') ->> 'done_today')::int,
  (select count(*)::int from marketplace_log where on_date = app.today() and kind in ('posted', 'renewed') and claim_id is null));
select test.ok('a teammate sees the listing but not who posted it', (select bool_and(t ->> 'poster' is null and t ->> 'url' is null)
  from jsonb_array_elements(public.door(test.id('mkt_s2'), 'aal2', 'va_read', 'mp_team', '{}') -> 'team') t where (t ->> 'id')::uuid = (select id from mkt_c)));
select test.ok('Admin sees who posted what', exists (select 1 from jsonb_array_elements(public.door(test.id('mkt_admin'), 'aal2', 'admin_read', 'marketplace', '{}') -> 'team') t
  where (t ->> 'id')::uuid = (select id from mkt_c) and t ->> 'poster' = 'Mkt S1' and t ->> 'url' like 'https://www.facebook.com/%'));

select public.door(test.id('mkt_admin'), 'aal2', 'admin_do', 'marketplace_log', jsonb_build_object('kind', 'posted', 'vehicle', test.id('vehicle:MKT1'),
  'url', 'https://www.facebook.com/marketplace/item/2000000000000/', 'title', 'Book this 2023 Toyota Camry by the day, from $89/day', 'body', 'Owner copy. Daily and weekly bookings only, not for sale.'));
select test.throws('the owner''s copy cannot be claimed again', $$select pg_temp.claim('mkt_s2', 3, 'Book this 2023 Toyota Camry by the day, from $89/day')$$, 'already live');
select pg_temp.claim('mkt_s2', 3);
select pg_temp.claim('mkt_s3', 4);
select pg_temp.claim('mkt_s4', 5);
select test.eq('five listings of the car: the owner''s and four of the team', (select count(*)::int from marketplace_claims where vehicle_id = test.id('vehicle:MKT1') and status <> 'ended') + 1, 5);
select test.throws('a sixth is refused', $$select pg_temp.claim('mkt_admin', 6)$$, 'from 2 to 5');
update program_settings set marketplace_max_live_per_car = 6 where id = (app.settings()).id;
select test.ok('a higher limit allows another variant', (pg_temp.claim('mkt_admin', 6) ->> 'status') = 'claimed');
update program_settings set marketplace_max_live_per_car = 5 where id = (app.settings()).id;
select test.throws('at the limit, no new listing even in a free variant', $$select public.door(test.id('mkt_s1'), 'aal2', 'va_do', 'mp_team_log', jsonb_build_object('claim', (select id from mkt_c), 'kind', 'removed'));
  select pg_temp.claim('mkt_s1', 2, 'A fresh title for the Camry', 'c/fresh.jpg')$$, 'already has 5 live listings');

-- ending: taken down, a claim not posted within a day, a listing past its lifetime
select pg_temp.lg('mkt_s1', (select id from mkt_c), 'removed');
select test.ok('taken down: ended, and the variant is free again', exists (select 1 from marketplace_claims where id = (select id from mkt_c) and status = 'ended' and ended_reason = 'Taken down'));
select test.throws('an ended listing cannot be renewed', format($s$select pg_temp.lg('mkt_s1', %L, 'renewed')$s$, (select id from mkt_c)), 'has ended');
update marketplace_claims set expires_at = now() - interval '1 minute' where poster_id = test.id('mkt_s4');
select test.ok('a variant past its time can be claimed by someone else', (pg_temp.claim('mkt_s1', 5) ->> 'variant')::int = 5);
select test.ok('the lapsed claim ended with its reason', exists (select 1 from marketplace_claims where poster_id = test.id('mkt_s4') and status = 'ended' and ended_reason like 'Not posted%'));
select test.ok('every claim not ended has its own variant, title, description and cover', (select count(*) = count(distinct variant) and count(*) = count(distinct lower(title))
  and count(*) = count(distinct body_hash) and count(*) = count(distinct cover) from marketplace_claims where vehicle_id = test.id('vehicle:MKT1') and status <> 'ended'));

-- the inbox: the numbers are leads assigned to the salesperson
select public.door(test.id('mkt_s2'), 'aal2', 'va_do', 'mp_team_inbox', jsonb_build_object('conversations', 5, 'replies', 6, 'numbers_text', 'Riley, 416 555 0177'));
select test.ok('the number is a Marketplace lead credited to the salesperson', exists (select 1 from leads where phone = '+14165550177' and source = 'fb_marketplace' and assigned_to = test.id('mkt_s2')));
select test.ok('with the call-back task', exists (select 1 from tasks t join leads l on l.id = t.related_id where l.phone = '+14165550177' and t.task_type = 'marketplace_callback'));
select test.ok('and the session in their log', exists (select 1 from marketplace_log where kind = 'inbox' and logged_by = test.id('mkt_s2') and conversations = 5 and numbers = 1));
select test.throws('customer service cannot log a team inbox here', format($s$select public.door(%L, 'aal2', 'va_do', 'mp_team_inbox', '{"conversations": 1}')$s$, test.id('mkt_cs')), 'Sales and Admins');

-- Stuck? help
select test.ok('the settings for the browser', public.help_stuck_settings() = '{"on": true, "idle_minutes": 3, "errors": 3}'::jsonb);
select test.ok('an event is logged', public.help_stuck_log(test.id('mkt_s1'), '{"portal": "va", "route": "/staff/marketing", "trigger": "idle", "action": "shown"}'));
select public.help_stuck_log(test.id('mkt_s2'), '{"portal": "va", "route": "/staff/marketing", "trigger": "errors", "action": "shown"}');
select public.help_stuck_log(test.id('mkt_s2'), '{"portal": "va", "route": "/staff/marketing", "action": "guide"}');
select public.help_stuck_log(test.id('mkt_admin'), '{"portal": "admin", "route": "/admin/bookings/[id]", "tab": "money", "trigger": "loop", "action": "shown"}');
select test.throws('an unknown action is refused', format($s$select public.help_stuck_log(%L, '{"portal": "va", "route": "/x", "action": "hack"}')$s$, test.id('mkt_s1')), 'Not a help event');
select test.ok('no one signed in: nothing logged', not public.help_stuck_log(null, '{"portal": "va", "route": "/x", "action": "shown"}'));
create temp table mkt_h as select public.door(test.id('mkt_admin'), 'aal2', 'admin_read', 'help_stuck', '{}') r;
select test.eq('Admin: the page that triggers it most comes first', (select r -> 'pages' -> 0 ->> 'route' from mkt_h), '/staff/marketing');
select test.eq('with how often it showed and the guide opened', (select (r -> 'pages' -> 0 ->> 'shown')::int * 10 + (r -> 'pages' -> 0 ->> 'guide')::int from mkt_h), 21);
select test.throws('the report is Admin''s', format($s$select public.door(%L, 'aal2', 'admin_read', 'help_stuck', '{}')$s$, test.id('mkt_s1')));
select test.ok('the browser cannot write the table directly', not has_table_privilege('authenticated', 'help_stuck_events', 'insert'));

-- the guides and the Academy (0511)
select test.ok('the Academy section is last on both Sales paths, with its lessons and quiz', (select count(*) = 2 from academy_path_sections ps join academy_sections s on s.id = ps.section_id
  where s.slug = 'marketplace-with-claude' and ps.path_code in ('sales_in_person', 'sales_remote')
    and ps.sort = (select max(sort) from academy_path_sections x where x.path_code = ps.path_code))
  and (select count(*) from academy_lessons l join academy_sections s on s.id = l.section_id where s.slug = 'marketplace-with-claude') = 2
  and (select count(*) from academy_questions q join academy_sections s on s.id = q.section_id where s.slug = 'marketplace-with-claude') = 5);
