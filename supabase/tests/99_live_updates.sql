-- 99: live updates (migration 2500): topics are handed out only to who may read them, a change bumps its topics at
-- commit, and live_poll answers versions by name only. Fixtures start with "lvu". Each statement here is its own
-- transaction (psql autocommit), so the deferred bump has run when the next line reads.
select test.suite('99 live updates');
select test.mk_user('lvu_admin', 'admin');
select test.mk_user('lvu_cs', 'va', 'cs');
select test.mk_user('lvu_field', 'field');
select test.mk_owner('lvu_owner');
select test.mk_vehicle('lvu_car', 'lvu_owner');
select test.mk_renter('lvu_renter');
select test.mk_renter('lvu_other');
select test.mk_booking('LVU-1', 'lvu_car', 'lvu_renter', '2031-03-02 10:00', '2031-03-05 10:00', 'confirmed');

create temp table lvu_t as
select (public.server_live_topics(test.id('lvu_admin'), array['staff:bookings', 'staff:leads', 'staff:field', 'booking:LVU-1', 'user:' || test.id('lvu_admin'), 'user:' || test.id('lvu_cs')])) as admin,
       (public.server_live_topics(test.id('lvu_cs'), array['staff:bookings', 'staff:requests', 'booking:LVU-1'])) as cs,
       (public.server_live_topics(test.id('lvu_field'), array['staff:bookings', 'staff:field', 'booking:LVU-1'])) as field,
       (public.server_live_topics(test.id('lvu_renter'), array['staff:bookings', 'booking:LVU-1', 'renter:' || test.id('lvu_renter'), 'renter:' || test.id('lvu_other')])) as renter,
       (public.server_live_topics(test.id('lvu_other'), array['booking:LVU-1', 'booking:NOPE-9'])) as other,
       (public.server_live_topics(test.id('lvu_owner'), array['booking:LVU-1', 'owner:' || test.id('lvu_owner'), 'staff:bookings'])) as owner;

select test.ok('Admin: staff areas, the booking and their own alerts; not another person''s',
  (select admin ?& array['staff:bookings', 'staff:leads', 'staff:field', 'booking:LVU-1', 'user:' || test.id('lvu_admin')] and not admin ? ('user:' || test.id('lvu_cs')) from lvu_t));
select test.ok('office staff: the office areas and any booking', (select cs ?& array['staff:bookings', 'staff:requests', 'booking:LVU-1'] from lvu_t));
select test.ok('field staff: the field area only (not bookings, not a booking they have no job on)',
  (select field ? 'staff:field' and not field ? 'staff:bookings' and not field ? 'booking:LVU-1' from lvu_t));
select test.ok('a renter: their booking and their own trips; no staff area, not another renter''s trips',
  (select renter ?& array['booking:LVU-1', 'renter:' || test.id('lvu_renter')] and not renter ? 'staff:bookings' and not renter ? ('renter:' || test.id('lvu_other')) from lvu_t));
select test.eq('another renter: nothing of this booking (and nothing of a booking that does not exist)', (select other from lvu_t), '{}'::jsonb);
select test.ok('the owner: the booking of their car and their own dashboard; no staff area',
  (select owner ?& array['booking:LVU-1', 'owner:' || test.id('lvu_owner')] and not owner ? 'staff:bookings' from lvu_t));
select test.ok('names are 32 hex characters and the same for everyone who may read the scope',
  (select (admin ->> 'booking:LVU-1') ~ '^[0-9a-f]{32}$' and admin ->> 'booking:LVU-1' = renter ->> 'booking:LVU-1' and admin ->> 'staff:bookings' = cs ->> 'staff:bookings' from lvu_t));

-- a change bumps the booking, the staff area, the renter's trips and the owner's dashboard
create temp table lvu_v0 as select public.live_poll(array[admin ->> 'booking:LVU-1', admin ->> 'staff:bookings', renter ->> ('renter:' || test.id('lvu_renter')), owner ->> ('owner:' || test.id('lvu_owner')), admin ->> 'staff:leads']) as v from lvu_t;
update bookings set pickup_place = 'Live street' where booking_number = 'LVU-1';
create temp table lvu_v1 as select public.live_poll(array[admin ->> 'booking:LVU-1', admin ->> 'staff:bookings', renter ->> ('renter:' || test.id('lvu_renter')), owner ->> ('owner:' || test.id('lvu_owner')), admin ->> 'staff:leads']) as v from lvu_t;
select test.ok('the booking''s change bumps its booking, the bookings area, the renter''s trips and the owner''s dashboard',
  (select (select count(*) from lvu_t t, jsonb_each_text(v1.v) e
            where e.key in (t.admin ->> 'booking:LVU-1', t.admin ->> 'staff:bookings', t.renter ->> ('renter:' || test.id('lvu_renter')), t.owner ->> ('owner:' || test.id('lvu_owner')))
              and e.value is distinct from (v0.v ->> e.key)) = 4 from lvu_v0 v0, lvu_v1 v1));
select test.ok('an area nothing changed in keeps its version', (select (v1.v -> (t.admin ->> 'staff:leads')) is not distinct from (v0.v -> (t.admin ->> 'staff:leads')) from lvu_v0 v0, lvu_v1 v1, lvu_t t));
create temp table lvu_b0 as select (select ver from app.live_versions where topic = (select admin ->> 'booking:LVU-1' from lvu_t)) as v;
update booking_line_items set booking_id = booking_id where booking_id = test.id('booking:LVU-1');
select test.ok('a change to a child row of the booking (its charges) bumps the booking',
  (select ver from app.live_versions where topic = (select admin ->> 'booking:LVU-1' from lvu_t)) > (select v from lvu_b0));

-- one bump per topic per transaction, however many statements touched it
create temp table lvu_c0 as select (select ver from app.live_versions where topic = (select admin ->> 'staff:bookings' from lvu_t)) as v;
do $$ begin
  update bookings set pickup_place = 'One' where booking_number = 'LVU-1';
  update bookings set pickup_place = 'Two' where booking_number = 'LVU-1';
end $$;
select test.eq('two statements in one transaction: one bump', (select ver from app.live_versions where topic = (select admin ->> 'staff:bookings' from lvu_t)) - (select v from lvu_c0), 1::bigint);
select test.eq('nothing waits after the commit', (select count(*) from app.live_flush), 0::bigint);

-- an alert bumps the person's own topic
create temp table lvu_a0 as select coalesce((select ver from app.live_versions where topic = (select admin ->> ('user:' || test.id('lvu_admin')) from lvu_t)), 0) as v;
insert into notifications (user_id, code, title, dedupe_key) select test.id('lvu_admin'), code, 'Live test', 'lvu-live-test' from notification_catalogue limit 1;
select test.ok('a new alert bumps the person''s own topic', (select coalesce((select ver from app.live_versions where topic = (select admin ->> ('user:' || test.id('lvu_admin')) from lvu_t)), 0)) > (select v from lvu_a0));

-- a statement that changes nothing bumps nothing; a failed bump never fails the write
create temp table lvu_n0 as select (select ver from app.live_versions where topic = (select admin ->> 'staff:bookings' from lvu_t)) as v;
update bookings set pickup_place = 'x' where false;
select test.eq('no rows changed, no bump', (select ver from app.live_versions where topic = (select admin ->> 'staff:bookings' from lvu_t)), (select v from lvu_n0));

-- the doors
select test.eq('live_poll: names only (anything else is ignored), at most 24', public.live_poll(array['staff:bookings', 'not a name']), '{}'::jsonb);
select test.ok('live_poll answers anonymous callers; server_live_topics does not',
  has_function_privilege('anon', 'public.live_poll(text[])', 'execute') and not has_function_privilege('anon', 'public.server_live_topics(uuid, text[])', 'execute')
  and not has_function_privilege('authenticated', 'public.server_live_topics(uuid, text[])', 'execute'));
select test.ok('the key and the versions are not readable by the API roles',
  not has_table_privilege('anon', 'app.live_key', 'select') and not has_table_privilege('authenticated', 'app.live_versions', 'select'));
