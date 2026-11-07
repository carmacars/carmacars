-- 0620_staff_listing_link.sql
-- Release 31 "Simple" (docs/changes/2026-11-07-simple-portals.md, shared pages): the Fleet alert "a listing waits for
-- review" linked /staff/listings/<vehicle id>, but /staff/listings/[id] takes a listing review (intake) id, so every such
-- link answered 404 (found by the role crawl). The link now opens the car's page on its Listing tab, the shared vehicle
-- page staff have: the listing state, Publish now and the open items. The links already written are corrected the same
-- way, only where the id is a car's (never an intake's). No other change. (0620: clear of 0601-0619, the licence reader.)

update notification_link_paths set path = '/staff/vehicles/{{vehicle_id}}?tab=listing'
 where key = 'va_fleet_listing';
update notification_catalogue set link_path = '/staff/vehicles/{{vehicle_id}}?tab=listing'
 where link_path = '/staff/listings/{{vehicle_id}}';

create function pg_temp.listing_link(p text) returns text language sql stable as $$
  select case
    when p ~ '/staff/listings/[0-9a-f-]{36}'
     and exists (select 1 from vehicles v where v.id::text = substring(p from '/staff/listings/([0-9a-f-]{36})'))
     and not exists (select 1 from listing_intakes i where i.id::text = substring(p from '/staff/listings/([0-9a-f-]{36})'))
    then regexp_replace(p, '/staff/listings/([0-9a-f-]{36})', '/staff/vehicles/\1?tab=listing')
    else p end
$$;
update notifications set url = pg_temp.listing_link(url) where url ~ '/staff/listings/[0-9a-f-]{36}';
update staff_digest_items set url = pg_temp.listing_link(url) where url ~ '/staff/listings/[0-9a-f-]{36}';
update push_outbox set url = pg_temp.listing_link(url) where url ~ '/staff/listings/[0-9a-f-]{36}';
