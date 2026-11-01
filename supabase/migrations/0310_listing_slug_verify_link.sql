-- 0310_listing_slug_verify_link.sql
-- Two links that answered 404 (docs/changes/2026-11-05-listing-slug-verify-link.md), found by the role crawls of the
-- Release 25 run once its new tests moved other specs between the parallel parts.
--
-- 1. A published car with no address. A listing could be set to published without a slug (the publish screens give
--    one, but nothing else made sure): the fleet then had a car at /cars/null, linked from the home page, Cars, Delivery,
--    Requirements and the class pages. Now a listing that becomes published without a slug gets one at once
--    (app.listing_slug, the publish screens' own rule), and the published ones without a slug get theirs now.
-- 2. A queue link customer service could not open. A renter's licence task stays in customer service's queue while the
--    request is still with Sales, and Sales can review the photos (0169). Once nothing was waiting the review page
--    refused customer service (it opened only for a booking awaiting payment, confirmed or on rent, or with photos
--    waiting), so the task's "Review" link answered 404. Customer service may now open the review of a booking whose
--    review task is open in their queue.
-- No applied migration is edited.

-- ================================================================ 1. no published listing without a slug
create or replace function app.listing_slug_on_publish() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = 'published' and new.slug is null then
    new.slug := app.listing_slug(new.vehicle_id);
  end if;
  return new;
end $$;
drop trigger if exists a0_listing_slug_on_publish on vehicle_listings;
create trigger a0_listing_slug_on_publish before insert or update of status, slug on vehicle_listings
  for each row execute function app.listing_slug_on_publish();

do $$
declare r record;
begin
  for r in select l.vehicle_id from vehicle_listings l where l.status = 'published' and l.slug is null order by l.vehicle_id loop
    update vehicle_listings set slug = app.listing_slug(r.vehicle_id) where vehicle_id = r.vehicle_id and slug is null;
  end loop;
end $$;

-- ================================================================ 2. the review page opens for the task in the queue
alter function app.doc_review_can(uuid, uuid) rename to doc_review_can_pre0310;
create function app.doc_review_can(p_by uuid, p_booking uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.doc_review_can_pre0310(p_by, p_booking)
      or (app.user_va_has(p_by, 'cs') and exists (
            select 1 from tasks t
             where t.booking_id = p_booking and t.queue = 'cs' and t.status in ('open', 'in_progress', 'waiting')
               and t.task_type in ('verify_renter', 'chase_verification', 'protection_plan_request', 'coverage_review')))
$$;

-- ================================================================ privileges
revoke all on function app.listing_slug_on_publish() from public, anon, authenticated;
grant execute on function app.listing_slug_on_publish() to service_role;
do $$
declare g text;
begin
  execute 'revoke all on function app.doc_review_can(uuid, uuid) from public, anon, authenticated';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.doc_review_can_pre0310(uuid, uuid)'::regprocedure, 'execute') then
      execute format('grant execute on function app.doc_review_can(uuid, uuid) to %I', g);
    end if;
  end loop;
  execute 'revoke all on function app.doc_review_can_pre0310(uuid, uuid) from public, anon, authenticated';
  execute 'grant execute on function app.doc_review_can_pre0310(uuid, uuid) to service_role';
end $$;
