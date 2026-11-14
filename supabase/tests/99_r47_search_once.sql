-- 99_r47_search_once: the cars list for chosen dates prices each car once (2903). Fixtures start with "so47".
select test.suite('99 r47 search prices each car once');

select test.ok('the inner query is its own step (offset 0)',
  pg_get_functiondef('app.search_available(timestamptz, timestamptz, jsonb)'::regprocedure) like '%offset 0) q%');

update program_settings set listing_publish_new_cars_automatically = false, listing_plate_check_required = false;
select test.mk_user('so47_admin', 'admin');
select test.mk_owner('so47_own');
select test.mk_vehicle('SO47A', 'so47_own');
do $$ begin
  perform app.ensure_listing(test.id('vehicle:SO47A'));
  perform app.listing_publish_now(test.id('so47_admin'), jsonb_build_object('vehicle_id', test.id('vehicle:SO47A')));
end $$;

begin;
set local track_functions = 'all';
create temp table so47_before as select coalesce(sum(calls), 0) n from pg_stat_xact_user_functions where funcname = 'price_quote';
create temp table so47_rows as
  select * from public.search_available(now() + interval '20 days', now() + interval '51 days', '{}');
select test.ok('the car is in the list for a 31-day rental, with its price',
  exists (select 1 from so47_rows where vehicle_id = test.id('vehicle:SO47A') and total_cents > 0 and billable_days = 31));
select test.eq('price_quote ran once a car listed',
  ((select coalesce(sum(calls), 0) from pg_stat_xact_user_functions where funcname = 'price_quote') - (select n from so47_before))::text,
  (select count(*) from so47_rows)::text);
commit;
