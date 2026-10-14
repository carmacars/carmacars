-- 0035_launch_audit.sql
-- What the launch audit (docs/audit/2026-10-13-launch-audit.md) changed in the database:
--   1. sample cars: vehicles.is_sample marks the 20 placeholder cars the seed puts on a new site. A sample car
--      stays on the fleet page and takes requests as before, but its page is noindex, it is left out of the
--      sitemap (and so is a model page whose every car is a sample), and Admin > Today lists it as a setup
--      item. An Admin clears the flag on the vehicle's Listing tab (admin_do 'vehicle_sample').
--   2. a review is published only with the renter's consent to publish (reviews.publish_consent_at, 0034).
--   3. marketing emails wait while the mailing address is missing (0025 item 8; the anti-spam law requires the
--      address in every commercial email): app.outbox_claim leaves them delayed, retried every hour.

-- ================================================================ 1. sample cars
alter table vehicles add column if not exists is_sample boolean not null default false;
comment on column vehicles.is_sample is
  'A placeholder car from the seed (0035): noindex, not in the sitemap, listed in Admin > Today until an Admin clears it';

-- The cars the seed added: the sample owner's (scripts/seed.mjs), with the seed's VINs.
update vehicles v set is_sample = true
  from owners o
 where o.id = v.owner_id and o.email = 'sample.owner@example.test' and v.vin like 'SAMPLE%' and not v.is_sample;

-- The public row carries the flag (the website shows nothing different; it decides noindex).
create or replace function app.public_listing_row(p_vehicle uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'app'
AS $function$
  select jsonb_build_object(
    'vehicle_id', v.id, 'slug', l.slug, 'path', '/cars/' || l.slug,
    'canonical_path', '/cars/' || coalesce((select c.slug from vehicle_listings c where c.vehicle_id = l.canonical_vehicle_id), l.slug),
    'headline', l.headline, 'year', v.year, 'make', v.make, 'model', v.model, 'trim', v.trim, 'colour', v.colour,
    'fuel', v.fuel, 'class', v.class, 'classes', app.vehicle_class_list(v.id), 'body_style', coalesce(l.body_style, v.body_type), 'seats', l.seats,
    'transmission', l.transmission, 'doors', l.doors, 'drivetrain', l.drivetrain, 'luggage', l.luggage,
    'home_area', l.home_area, 'allows_18_to_20', v.allows_18_to_20, 'is_featured', l.is_featured,
    'taking_requests', l.status = 'published' and pv.vehicle_id is not null,
    'model_hub_path', app.model_hub_path(v.make, v.model),
    'daily_rate_cents', rc.daily_rate_cents, 'weekend_rate_cents', rc.weekend_rate_cents, 'weekly_rate_cents', rc.weekly_rate_cents,
    'monthly_rate_cents', rc.monthly_rate_cents, 'km_allowance_per_day', rc.km_allowance_per_day,
    'overage_cents_per_km', rc.overage_cents_per_km, 'deposit_cents', rc.deposit_cents,
    'delivery_fee_cents', rc.delivery_fee_cents, 'pickup_fee_cents', rc.pickup_fee_cents,
    'cover', (select jsonb_build_object('path', ph.processed_path, 'variants', ph.variants, 'alt', ph.alt_text)
                from vehicle_photos ph where ph.vehicle_id = v.id and ph.is_cover and ph.is_public and ph.status = 'approved'
                 and ph.replaced_at is null limit 1),
    'is_sample', v.is_sample,
    'published_at', l.first_published_at, 'updated_at', l.content_updated_at)
    from vehicle_listings l join vehicles v on v.id = l.vehicle_id
    left join public_vehicle_listings pv on pv.vehicle_id = v.id
    left join rate_cards rc on rc.vehicle_id = v.id and rc.effective_from <= now() and (rc.effective_to is null or rc.effective_to > now())
   where l.vehicle_id = p_vehicle and l.status in ('published', 'paused') and v.management_mode <> 'turo_only'
$function$;

-- The car page: indexable only when it is the canonical unit and not a sample.
create or replace function app.public_car_page(p_slug text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(
    (select app.public_listing_row(l.vehicle_id) || jsonb_build_object(
              'description', l.description, 'features', to_jsonb(l.features),
              'faq', coalesce((select jsonb_agg(jsonb_build_object('question', e ->> 'question', 'answer', e ->> 'answer'))
                                 from jsonb_array_elements(l.faq) e), '[]'::jsonb),
              'specs', l.specs - array['vin', 'plate', 'owner', 'fleet_number'], 'staff_note', l.staff_note,
              'seo_title', l.seo_title, 'seo_description', l.seo_description,
              'indexable', l.canonical_vehicle_id is null and not v.is_sample, 'photos', app.public_listing_photos(l.vehicle_id))
       from vehicle_listings l join vehicles v on v.id = l.vehicle_id
      where l.slug = lower(btrim(p_slug)) and l.status in ('published', 'paused') and v.management_mode <> 'turo_only'),
    (select jsonb_build_object('redirect', r.to_path, 'status_code', r.status_code)
       from listing_redirects r where r.from_path = '/cars/' || lower(btrim(p_slug))))
$$;

-- A model page is indexable while at least one of its cars is real.
create or replace function app.public_model_hub(p_hub text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when count(*) = 0 then null else
    jsonb_build_object('make', min(v.make), 'model', min(v.model), 'path', '/rent/' || lower(btrim(p_hub)),
                       'min_daily_rate_cents', min((app.public_listing_row(l.vehicle_id) ->> 'daily_rate_cents')::bigint),
                       'indexable', bool_or(not v.is_sample),
                       'cars', jsonb_agg(app.public_listing_row(l.vehicle_id) order by l.first_published_at)) end
    from vehicle_listings l join vehicles v on v.id = l.vehicle_id
   where l.status = 'published' and v.management_mode <> 'turo_only'
     and app.slugify(v.make || ' ' || v.model) = lower(btrim(p_hub))
$$;

-- Sitemap rows: canonical car pages that are not samples, and model pages with a real car.
create or replace function app.public_sitemap() returns table (path text, kind text, lastmod timestamptz)
language sql stable security definer set search_path = public, app as $$
  with cars as (
    select l.slug, v.make, v.model, l.canonical_vehicle_id,
           greatest(l.content_updated_at,
                    (select max(ph.approved_at) from vehicle_photos ph where ph.vehicle_id = v.id and ph.is_public and ph.status = 'approved' and ph.replaced_at is null),
                    (select max(rc.created_at) from rate_cards rc where rc.vehicle_id = v.id and rc.effective_from <= now())) as lastmod
      from vehicle_listings l join vehicles v on v.id = l.vehicle_id
     where l.status in ('published', 'paused') and v.management_mode <> 'turo_only' and l.slug is not null and not v.is_sample)
  select '/cars/' || slug, 'car', lastmod from cars where canonical_vehicle_id is null
  union all
  select app.model_hub_path(min(make), min(model)), 'model_hub', max(lastmod) from cars group by app.slugify(make || ' ' || model)
  order by 2, 1
$$;

-- Admin > Today: the sample cars are a setup item until the real fleet replaces them.
create or replace function app.site_setup_problems() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(x), '[]'::jsonb) from (
    select jsonb_build_object('field', 'mailing_address', 'blocks', 'marketing_emails',
                              'message', 'Enter the mailing address before marketing emails go out') as x
      from site_settings s where s.singleton and s.mailing_address_required and nullif(btrim(coalesce(s.mailing_address, '')), '') is null
    union all
    select jsonb_build_object('field', 'street_address', 'blocks', null,
                              'message', 'Enter the street address; it is shown on the website once entered')
      from site_settings s where s.singleton and nullif(btrim(coalesce(s.street_address, '')), '') is null
    union all
    select jsonb_build_object('field', 'sample_cars', 'blocks', 'search_engines',
                              'message', format('%s sample %s on the website: hidden from search engines until the real cars replace them (unlist each sample, or clear "Sample car" on its Listing tab)',
                                                count(*), case when count(*) = 1 then 'car is' else 'cars are' end))
      from vehicles v join vehicle_listings l on l.vehicle_id = v.id
     where v.is_sample and l.status in ('published', 'paused')
    having count(*) > 0) q
$$;

-- ================================================================ 2 and 1. admin actions
-- The 0030 action list is kept; two actions are added or guarded in front of it.
alter function app.admin_do(uuid, text, jsonb) rename to admin_do_0030;

create or replace function app.admin_do(p_admin uuid, p_action text, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  v_before boolean;
  v_after boolean;
begin
  if p_action = 'vehicle_sample' then
    perform app.admin_begin(p_admin);
    v_after := coalesce((p_ ->> 'is_sample')::boolean, false);
    select is_sample into v_before from vehicles where id = (p_ ->> 'vehicle')::uuid;
    if not found then raise exception 'Vehicle not found' using errcode = 'P0002'; end if;
    update vehicles set is_sample = v_after where id = (p_ ->> 'vehicle')::uuid;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
    values (p_admin, 'set_sample_car', 'vehicles', p_ ->> 'vehicle', jsonb_build_object('is_sample', v_before), jsonb_build_object('is_sample', v_after));
    return jsonb_build_object('vehicle', p_ ->> 'vehicle', 'is_sample', v_after,
                              'slug', (select l.slug from vehicle_listings l where l.vehicle_id = (p_ ->> 'vehicle')::uuid));
  end if;
  if p_action = 'review_publish' then
    perform app.admin_begin(p_admin);
    if exists (select 1 from reviews r where r.id = (p_ ->> 'id')::uuid and r.publish_consent_at is null) then
      raise exception 'The renter did not agree to publish this review; keep it for internal use' using errcode = '23514';
    end if;
  end if;
  return app.admin_do_0030(p_admin, p_action, p_);
end $$;

revoke all on function app.admin_do(uuid, text, jsonb), app.admin_do_0030(uuid, text, jsonb) from public, anon, authenticated;
grant execute on function app.admin_do(uuid, text, jsonb), app.admin_do_0030(uuid, text, jsonb) to service_role;

-- ================================================================ 3. marketing waits for the mailing address
alter function app.outbox_claim(integer, timestamptz) rename to outbox_claim_0018;

create or replace function app.outbox_claim(p_limit integer default 20, p_now timestamptz default now())
returns table (id uuid, code text, category text, to_address text, to_name text, from_address text, reply_to text,
               subject text, payload jsonb, attempts integer, unsubscribe_url text, template_html text, template_text text)
language plpgsql security definer set search_path = public, app as $$
begin
  if exists (select 1 from site_settings s
              where s.singleton and s.mailing_address_required and nullif(btrim(coalesce(s.mailing_address, '')), '') is null) then
    update notification_outbox o
       set status = 'delayed', status_reason = 'waiting for the mailing address (Admin > Settings > Site)',
           send_after = p_now + interval '1 hour'
     where o.category = 'marketing' and o.status in ('queued', 'delayed') and o.send_after <= p_now;
  end if;
  return query select * from app.outbox_claim_0018(p_limit, p_now);
end $$;

revoke all on function app.outbox_claim(integer, timestamptz), app.outbox_claim_0018(integer, timestamptz) from public, anon, authenticated;
grant execute on function app.outbox_claim(integer, timestamptz), app.outbox_claim_0018(integer, timestamptz) to service_role;

-- ================================================================ 4. the owner FAQ on tracker fees
-- 0029: the first and last month's Insurance Fee is invoiced on its own and the Tracker Install Fee only once
-- the tracker is installed; the FAQ the seed wrote still put both before the car goes live. Changed only
-- where an Admin has not edited the answer (the seed adds content rows, it never overwrites them).
update site_content_blocks
   set data = replace(data::text, $q$Two monthly fees for each car: an insurance fee and a tracker fee. They are due every month whether the car is rented or not. Before the car goes live you pay the first and last month’s insurance fee and a tracker install fee. The amounts depend on how many cars you have with us and are confirmed on a call. There is no security deposit.$q$, $q$Two monthly fees for each car: an insurance fee and a tracker fee. They are due every month whether the car is rented or not; the tracker fee starts the day the car’s tracker is installed. Before the car goes live you pay the first and last month’s insurance fee. The tracker install fee is a separate invoice, sent once the tracker is installed. The amounts depend on how many cars you have with us and are confirmed on a call. There is no security deposit.$q$)::jsonb
 where data::text like '%' || $q$Two monthly fees for each car: an insurance fee and a tracker fee. They are due every month whether the car is rented or not. Before the car goes live you pay the first and last month’s insurance fee and a tracker install fee. The amounts depend on how many cars you have with us and are confirmed on a call. There is no security deposit.$q$ || '%';

-- ================================================================ 5. email lines that read like a form
-- Read at 375 and 640 px by the launch audit: with no field staff member assigned yet, the pickup and return
-- emails said "our team will meet you" at the start of a heading; the check-in email said "1 new damage item(s)";
-- the monthly owner invoice said "Debited from account ending ----" for a debit nothing runs yet; the payout email
-- named the last four digits of the owner's fee payment method instead of the payout account.
alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_0034;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_0034(p_code, p_event, p_to);
  n integer;
begin
  if x ->> 'field_staff_name' = 'our team' then x := x || jsonb_build_object('field_staff_name', 'Our team'); end if;
  if x ->> 'return_findings' ~ '^\d+ new damage item\(s\)' then
    n := (substring(x ->> 'return_findings' from '^(\d+)'))::integer;
    x := x || jsonb_build_object('return_findings',
      regexp_replace(x ->> 'return_findings', '^\d+ new damage item\(s\)', n || ' new damage ' || case when n = 1 then 'item' else 'items' end));
  end if;
  -- the monthly invoice: the debit on the 15th is not automated yet (0029, not done), so the email says how to pay
  -- instead of "debited from account ending ----"
  if p_code = 'owner_fee_invoice' then
    x := x || jsonb_build_object('bank_last4', case when coalesce(x ->> 'bank_last4', '----') = '----'
      then 'From the invoice page, by card or pre-authorized debit'
      else 'From the invoice page, with your saved method ending ' || (x ->> 'bank_last4') end);
  end if;
  -- money paid to the owner goes to the payout account, not the card or debit method the fees are paid with
  if p_code in ('owner_payout_sent', 'owner_bank_details_changed') then
    x := x || jsonb_build_object('bank_last4', coalesce(
      (select a.account_last4 from owner_payout_accounts a
        where a.owner_id = coalesce((p_event.payload ->> 'owner_id')::uuid, (p_to ->> 'owner_id')::uuid) and a.is_current limit 1),
      x ->> 'bank_last4'));
  end if;
  if p_code in ('investor_return_paid', 'owner_payout_sent') and coalesce(x ->> 'payout_reference', '') = '' then
    x := x || jsonb_build_object('payout_reference', 'Not recorded');
  end if;
  if p_code = 'staff_review_received' then
    if coalesce(x ->> 'review_title', '') = '' then x := x || jsonb_build_object('review_title', 'No title'); end if;
    if coalesce(x ->> 'review_text', '') = '' then x := x || jsonb_build_object('review_text', 'No comment written'); end if;
  end if;
  return x;
end $$;

-- ================================================================ 6. the registry visit email waits for its date
-- 0023 emailed "Registry visit booked: To be booked at" when the onboarding reached registry_booked before the
-- visit's date and time were entered. The email now goes when the visit has a date (and again when it moves).
create or replace function app.ntf_onboardings_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  pl jsonb := jsonb_build_object('vehicle_id', new.vehicle_id, 'owner_id', (select v.owner_id from vehicles v where v.id = new.vehicle_id));
  v_share boolean := (select v.is_shareholder_owned from vehicles v where v.id = new.vehicle_id);
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then
    if new.status = 'registry_booked' and new.registry_visit_at is not null
       and (new.registry_visit_at, new.registry_place) is distinct from (old.registry_visit_at, old.registry_place) then
      perform app.ntf_emit('owner_registry_visit', 'vehicle_onboarding', new.id, md5(coalesce(new.registry_visit_at::text, '') || coalesce(new.registry_place, '')), pl);
    end if;
    return null;
  end if;
  case new.status
    when 'documents_sent' then perform app.ntf_emit('owner_agreement_ready', 'vehicle_onboarding', new.id, 'documents_sent', pl);
    when 'documents_signed' then
      perform app.ntf_emit('owner_agreement_signed', 'vehicle_onboarding', new.id, 'documents_signed', pl);
      if v_share then perform app.ntf_emit('owner_onboarding_steps', 'vehicle_onboarding', new.id, 'steps', pl); end if;
    when 'upfront_paid' then perform app.ntf_emit('owner_onboarding_steps', 'vehicle_onboarding', new.id, 'steps', pl);
    when 'registry_booked' then
      if new.registry_visit_at is not null then
        perform app.ntf_emit('owner_registry_visit', 'vehicle_onboarding', new.id, md5(coalesce(new.registry_visit_at::text, '') || coalesce(new.registry_place, '')), pl);
      end if;
    when 'enrolled' then perform app.ntf_emit('owner_vehicle_enrolled', 'vehicle_onboarding', new.id, 'enrolled', pl);
    when 'declined' then perform app.ntf_emit('owner_application_declined', 'vehicle_onboarding', new.id, 'declined', pl);
    else null;
  end case;
  return null;
end $$;
