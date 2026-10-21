-- 0070_listing_no_roadblocks_coverage.sql
-- The owner, October 20, 2026:
--   "Listing a car must have NO roadblocks: a car can be published with only the basics (make, model, year, plate or
--    VIN, supply type, rates from defaults); everything else is a warning, not a blocker for the public listing, except
--    where the insurance policy legally requires the car to be on the fleet policy before a rental is handed over,
--    which stays a handover gate, not a listing gate."
--   "Renter coverage proof: OPCF 27 needs the policy document with insurer, policy number and expiry, reviewed by staff
--    before pickup; credit card coverage needs the booking paid with that same credit card (a credit card, not debit or
--    prepaid) and the renter's confirmation of the card's rental coverage, the card benefit proof optional; the
--    handover waits until it is confirmed; staff see it on the verification screen."
--
--   1. What blocks a listing now (app.publish_listing and the public listing view):
--        kept    the car is retired, closed (exited, total loss, declined) or out of service; Turo only; year, make and
--                model; the plate check on real photos (never with sample photos); a duplicate confirmed by staff; a
--                listing paused or bookings turned off by staff; a Self-Managed owner in arrears; the review of a
--                listing an owner or field staff submitted (staff publish at once)
--        warning onboarding steps (owner details, ownership permit, forms, agreements, upfront payment, registry,
--                tracker, enrollment), the insurer's confirmation (a handover gate), no rates (filled from similar cars),
--                colour, body style, seats, transmission (filled with defaults), photos (sample photos), the written
--                copy (written automatically), an open similarity flag
--   2. The handover: a program owner's car is not released before the insurer confirmed it on the fleet policy.
--   3. Coverage option 2 confirms itself once the booking is paid with a credit card and the renter confirmed the
--      card's rental coverage; option 1 needs the insurer, policy number and an expiry on or after the return date.
--
-- No earlier migration is edited: functions are replaced with the same signature or wrapped (suffix _pre0070).

-- ================================================================ 1. the listing: only the basics block
create or replace function app.listing_spec_problems(p_vehicle uuid) returns text[]
language sql stable security definer set search_path = public, app as $$
  select coalesce(array_agg(x.label order by x.ord) filter (where x.missing), '{}')
    from vehicles v,
         lateral (values (1, 'Year', v.year is null), (2, 'Make', nullif(btrim(v.make), '') is null),
                         (3, 'Model', nullif(btrim(v.model), '') is null),
                         (4, 'Plate or VIN', nullif(btrim(coalesce(v.plate, '')), '') is null and nullif(btrim(coalesce(v.vin, '')), '') is null)) x(ord, label, missing)
   where v.id = p_vehicle
$$;

-- The details that no longer block, for the warnings (they are filled with defaults when the listing is published).
create or replace function app.listing_spec_warnings(p_vehicle uuid) returns text[]
language sql stable security definer set search_path = public, app as $$
  select coalesce(array_agg(x.label order by x.ord) filter (where x.missing), '{}')
    from vehicles v left join vehicle_listings l on l.vehicle_id = v.id,
         lateral (values (1, 'Colour', nullif(btrim(v.colour), '') is null),
                         (2, 'Body style', coalesce(nullif(btrim(l.body_style), ''), nullif(btrim(v.body_type), '')) is null),
                         (3, 'Seats', l.seats is null), (4, 'Transmission', nullif(btrim(l.transmission), '') is null)) x(ord, label, missing)
   where v.id = p_vehicle
$$;

-- Rates from defaults: the median of similar cars (same model, then the class; app.rate_card_defaults), else of every
-- car of the class (sample cars too), else $75 a day. The weekend, weekly and monthly rates follow the daily rate where
-- similar cars do not give them (app.rate_card_check). Returns the new card, or null when a card is in force.
create or replace function app.listing_default_rates(p_vehicle uuid) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  s jsonb;
  v_daily bigint;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then return null; end if;
  if exists (select 1 from rate_cards rc where rc.vehicle_id = v.id and rc.effective_from <= now() and (rc.effective_to is null or rc.effective_to > now())) then
    return null;
  end if;
  s := app.rate_card_defaults(v.id) -> 'suggestion';
  if s is null or jsonb_typeof(s) <> 'object' then
    select jsonb_build_object('daily_cents', (round(percentile_cont(0.5) within group (order by r.daily_rate_cents) / 100) * 100)::bigint)
      into s
      from rate_cards r join vehicles x on x.id = r.vehicle_id
     where r.effective_from <= now() and (r.effective_to is null or r.effective_to > now()) and x.class = v.class and x.id <> v.id;
  end if;
  v_daily := coalesce(nullif(s ->> 'daily_cents', '')::bigint, 7500);
  return app.set_rate_card(v.id, v_daily, nullif(s ->> 'weekend_cents', '')::bigint, nullif(s ->> 'weekly_cents', '')::bigint,
                           nullif(s ->> 'monthly_cents', '')::bigint, now(), null, '{}'::jsonb);
end $$;

-- The listing's own details, filled where empty: the body style from the car, seats from the body style, an automatic
-- gearbox, and a headline from the year, make and model. Returns what was filled.
create or replace function app.listing_fill_defaults(p_vehicle uuid) returns text[]
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  l vehicle_listings;
  v_body text;
  v_out text[] := '{}';
begin
  select * into v from vehicles where id = p_vehicle;
  perform app.ensure_listing(p_vehicle);
  select * into l from vehicle_listings where vehicle_id = p_vehicle for update;
  v_body := coalesce(nullif(btrim(l.body_style), ''), nullif(btrim(v.body_type), ''));
  if nullif(btrim(l.body_style), '') is null and v_body is not null then v_out := v_out || 'body style'::text; end if;
  if l.seats is null then v_out := v_out || 'seats'::text; end if;
  if nullif(btrim(l.transmission), '') is null then v_out := v_out || 'transmission'::text; end if;
  if nullif(btrim(l.headline), '') is null then v_out := v_out || 'headline'::text; end if;
  update vehicle_listings
     set body_style = coalesce(nullif(btrim(body_style), ''), v_body),
         seats = coalesce(seats, case when v_body ~* 'minivan|van' then 7 when v_body ~* 'coupe|convertible|roadster' then 4 else 5 end),
         transmission = coalesce(nullif(btrim(transmission), ''), 'Automatic'),
         headline = coalesce(nullif(btrim(headline), ''), concat_ws(' ', v.year::text, v.make, v.model))
   where id = l.id;
  return v_out;
end $$;

-- Publishing (the base of the chain 0022 > 0040 > 0042 > 0054): the car's status may be onboarding (listed before its
-- paperwork is done), rates come from defaults, the details from defaults, photos and copy are warnings. The copy is
-- marked for a rewrite when it does not meet the copy rules, so the writer job fills it in.
create or replace function app.publish_listing_0022(p_vehicle uuid, p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  l vehicle_listings;
  i listing_intakes;
  ps program_settings := app.settings();
  v_role text := app.acting_role(p_by);
  v_problems text[];
  v_slug text;
  v_first boolean;
  v_rates uuid;
  v_filled text[];
  v_copy text[];
begin
  select * into v from vehicles where id = p_vehicle for update;
  if v.id is null then raise exception 'Vehicle not found' using errcode = 'P0002'; end if;
  perform app.ensure_listing(p_vehicle);
  select * into i from listing_intakes where vehicle_id = p_vehicle and state not in ('published', 'cancelled') order by created_at desc limit 1;

  if p_by is null then
    if i.id is null or i.state <> 'approved' then
      raise exception 'Cannot publish: nobody approved this listing' using errcode = '42501';
    end if;
  else
    if app.user_owns_vehicle(p_by, p_vehicle) and not app.user_is_admin(p_by) and not app.user_va_has(p_by) then v_role := 'owner'; end if;
    if v_role is null or (v_role = 'va' and not app.user_va_has(p_by, 'cs', 'fleet'))
       or (v_role = 'owner' and not app.user_owns_vehicle(p_by, p_vehicle))
       or (v_role = 'field' and not app.user_field_has_job(p_by, p_vehicle)) then
      raise exception 'Not permitted to publish this listing' using errcode = '42501';
    end if;
    if v_role = any (ps.listing_review_required_roles) and (i.id is null or i.state <> 'approved') then
      raise exception 'Cannot publish: a % listing is published after a CarmaCars review', v_role using errcode = '42501';
    end if;
  end if;

  if v.retired_at is not null or v.status not in ('onboarding', 'ready_to_list', 'available', 'on_rent', 'cleaning') then
    raise exception 'Cannot publish: the car is %', case when v.retired_at is not null then 'retired' else replace(v.status::text, '_', ' ') end using errcode = '23514';
  end if;
  if v.management_mode = 'turo_only' then
    raise exception 'Cannot publish: a Turo-Only vehicle is not listed on the CarmaCars website' using errcode = '23514';
  end if;
  v_problems := app.listing_spec_problems(v.id);
  if cardinality(v_problems) > 0 then
    raise exception 'Cannot publish: details missing: %', array_to_string(v_problems, ', ') using errcode = '23514';
  end if;
  v_rates := app.listing_default_rates(v.id);
  v_filled := app.listing_fill_defaults(v.id);
  select * into l from vehicle_listings where vehicle_id = p_vehicle for update;
  v_copy := app.listing_copy_problems(l.headline, l.description, l.features, l.faq);
  if l.canonical_vehicle_id is not null and not exists (
       select 1 from vehicle_listings c where c.vehicle_id = l.canonical_vehicle_id and c.status in ('published', 'paused') and c.canonical_vehicle_id is null) then
    update vehicle_listings set canonical_vehicle_id = null where id = l.id;
  end if;

  v_slug := coalesce(l.slug, app.listing_slug(v.id));
  v_first := l.first_published_at is null;
  update vehicle_listings
     set slug = v_slug, status = 'published', published_at = now(), first_published_at = coalesce(first_published_at, now()),
         published_by = p_by, unpublished_at = null, unpublished_reason = null, redirect_to = null, needs_rewrite = cardinality(v_copy) > 0,
         channels = case when 'website' = any (channels) then channels else channels || 'website'::text end
   where id = l.id;
  delete from listing_redirects where from_path = '/cars/' || v_slug;
  update vehicle_photos set is_public = st.is_public
    from listing_shot_types st
   where st.code = vehicle_photos.shot_type and vehicle_photos.vehicle_id = v.id and vehicle_photos.replaced_at is null
     and vehicle_photos.status = 'approved';
  if v.status = 'ready_to_list' then
    update vehicles set status = 'available' where id = v.id;
  end if;
  if i.id is not null then
    update listing_intakes set state = 'published', published_at = now() where id = i.id;
  end if;
  update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'listing published'
   where vehicle_id = v.id and task_type in ('list_vehicle', 'review_listing', 'listing_failed') and status in ('open', 'in_progress', 'waiting');
  perform app.emit_event('owner_vehicle_listed', 'vehicle', v.id,
    jsonb_build_object('owner_id', v.owner_id, 'vehicle_name', app.vehicle_name(v.id), 'listing_path', '/cars/' || v_slug,
                       'first_time', v_first),
    'owner_vehicle_listed:' || v.id || ':' || coalesce(i.id::text, to_char(now(), 'YYYYMMDDHH24MISS')));
  if v_rates is not null or cardinality(v_filled) > 0 then
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'listing_defaults', 'vehicles', v.id::text,
            jsonb_build_object('rate_card', v_rates, 'filled', to_jsonb(v_filled), 'copy_for_rewrite', to_jsonb(v_copy)));
  end if;
  return jsonb_build_object('status', 'published', 'vehicle_id', v.id, 'slug', v_slug, 'path', '/cars/' || v_slug, 'first_time', v_first,
                            'rates_from_defaults', v_rates is not null, 'filled', to_jsonb(v_filled), 'warnings', app.vehicle_listing_warnings(v.id));
end $$;

-- Similar cars (0040): an open flag is for information; only a duplicate confirmed by staff keeps a car off the site.
create or replace function app.publish_listing_0040(p_vehicle uuid, p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (app.settings()).listing_similarity_enabled then
    perform app.check_listing_similarity(p_vehicle, 'copy');
    if exists (select 1 from listing_similarity_flags x where x.vehicle_id = p_vehicle and x.status = 'confirmed' and x.blocking) then
      raise exception 'Staff confirmed this car is a duplicate of another listing: it is not published' using errcode = '23514';
    end if;
  end if;
  return app.publish_listing_0022(p_vehicle, p_by);
end $$;

-- The public site: a published listing of a car in onboarding is public too (its paperwork is a warning).
create or replace view public_vehicle_listings with (security_barrier = true) as
  select l.slug, l.headline, l.description, l.features, l.seats, l.transmission,
         v.id as vehicle_id, v.year, v.make, v.model, v.trim, v.colour, v.fuel, v.class, v.allows_18_to_20,
         rc.daily_rate_cents, rc.weekend_rate_cents, rc.weekly_rate_cents, rc.monthly_rate_cents,
         rc.km_allowance_per_day, rc.overage_cents_per_km, rc.deposit_cents, rc.delivery_fee_cents, rc.pickup_fee_cents
    from vehicle_listings l
    join vehicles v on v.id = l.vehicle_id
    join rate_cards rc on rc.vehicle_id = v.id and rc.effective_from <= now() and (rc.effective_to is null or rc.effective_to > now())
   where l.status = 'published' and v.management_mode <> 'turo_only' and v.retired_at is null
     and v.bookings_enabled and v.status in ('onboarding', 'ready_to_list', 'available', 'on_rent', 'cleaning')
     and not (v.management_mode = 'self_managed' and v.in_arrears);

-- A listed car keeps its live status through its paperwork: the enrollment (0011) moves a car to ready to list; a car
-- that is already available, on rent or cleaning stays so, and a published car in onboarding becomes available.
insert into status_transitions (entity, from_status, to_status, note) values
  ('vehicle', 'onboarding', 'available', 'listed before its paperwork was done: enrolled, or released at its first handover once on the fleet policy')
on conflict do nothing;

create or replace function app.vehicles_keep_live_status() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = 'ready_to_list' and old.status in ('available', 'on_rent', 'cleaning') then
    new.status := old.status;
  elsif new.status = 'ready_to_list' and old.status = 'onboarding'
        and exists (select 1 from vehicle_listings l where l.vehicle_id = new.id and l.status = 'published') then
    new.status := 'available';
  end if;
  return new;
end $$;
create trigger a00_keep_live_status before update of status on vehicles
  for each row execute function app.vehicles_keep_live_status();

-- A program owner's car listed before its Vehicle Schedule is signed takes requests on the owner's agreed terms or, when
-- none are set, the standard grid (app.owner_terms_resolve, 0067): the split is never left empty.
create or replace function app.bookings_default_share() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.company_share_bps is null and new.booking_type <> 'owner' then
    new.company_share_bps := nullif(app.owner_terms_resolve(new.vehicle_id, app.local_date(coalesce(new.booked_at, now()))) ->> 'revenue_share_bps', '')::integer;
  end if;
  return new;
end $$;
create trigger bookings_before_write_z70_share before insert on bookings
  for each row execute function app.bookings_default_share();

-- ================================================================ 2. why a car is not on the site, and the warnings
-- What still keeps a real car off the site (the blockers kept above). Empty: on the site, or it publishes in one click.
create or replace function app.vehicle_public_gates(p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  l vehicle_listings;
  g jsonb := '[]'::jsonb;
  v_problems text[];
  v_open text[];
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then return jsonb_build_array(jsonb_build_object('code', 'missing', 'label', 'Car not found', 'action', 'None', 'who', 'carmacars')); end if;
  if v.retired_at is not null then
    return jsonb_build_array(jsonb_build_object('code', 'retired', 'label', 'Retired', 'action', 'Restore the car (Admin > Cars > the car > Retire or delete)', 'who', 'carmacars'));
  end if;
  if v.status in ('exited', 'total_loss', 'declined') then
    return jsonb_build_array(jsonb_build_object('code', 'closed', 'label', 'Left the program (' || v.status || ')', 'action', 'None: the car is no longer in the program', 'who', 'carmacars'));
  end if;
  if v.management_mode = 'turo_only' then
    return jsonb_build_array(jsonb_build_object('code', 'turo_only', 'label', 'Turo only', 'action', 'None: a Turo-only car is not listed on the website', 'who', 'carmacars'));
  end if;
  if exists (select 1 from public_vehicle_listings p where p.vehicle_id = v.id) then return '[]'::jsonb; end if;
  select * into l from vehicle_listings where vehicle_id = v.id;
  if v.status not in ('onboarding', 'ready_to_list', 'available', 'on_rent', 'cleaning') then
    g := g || jsonb_build_object('code', 'status', 'label', 'Out of service (' || replace(v.status::text, '_', ' ') || ')', 'action', 'Put the car back in service', 'who', 'carmacars');
  end if;
  v_problems := app.listing_spec_problems(v.id);
  if cardinality(v_problems) > 0 then
    g := g || jsonb_build_object('code', 'details', 'label', 'Details missing', 'action', 'Enter the ' || lower(array_to_string(v_problems, ', ')), 'who', 'carmacars');
  end if;
  if (app.settings()).listing_plate_check_required and not app.vehicle_uses_sample_photos(v.id) then
    select array_agg(coalesce(st.label, ph.shot_type) order by st.seq, ph.sort_order) into v_open
      from vehicle_photos ph join listing_shot_types st on st.code = ph.shot_type
     where ph.vehicle_id = v.id and ph.replaced_at is null and ph.status = 'approved' and ph.is_public and st.is_public
       and ph.processed_path is not null and ph.plate_status = 'unchecked';
    if cardinality(v_open) > 0 then
      g := g || jsonb_build_object('code', 'plates', 'label', 'Plate check', 'action', 'Cover the plate or mark it not visible: ' || array_to_string(v_open, ', '), 'who', 'carmacars');
    end if;
  end if;
  if exists (select 1 from listing_similarity_flags x where x.vehicle_id = v.id and x.status = 'confirmed' and x.blocking) then
    g := g || jsonb_build_object('code', 'duplicate', 'label', 'Confirmed duplicate', 'action', 'Clear the duplicate under Admin > Similar cars', 'who', 'carmacars');
  end if;
  if l.id is null or l.status not in ('published', 'paused') then
    g := g || jsonb_build_object('code', 'listing', 'label', case when l.publish_at > now() then 'Listing scheduled' else 'Not published yet' end,
                                 'action', case when l.publish_at > now() then 'Nothing: it publishes on ' || app.fmt_day(app.local_date(l.publish_at))
                                                else 'Publish (Admin > Cars > the car > Listing): rates, details and photos are filled in by default' end,
                                 'who', 'carmacars');
  elsif l.status = 'paused' then
    g := g || jsonb_build_object('code', 'paused', 'label', 'Listing paused', 'action', 'Resume the listing', 'who', 'carmacars');
  end if;
  if not v.bookings_enabled then
    g := g || jsonb_build_object('code', 'bookings_off', 'label', 'Bookings turned off', 'action', 'Turn bookings on for the car', 'who', 'carmacars');
  end if;
  if v.management_mode = 'self_managed' and v.in_arrears then
    g := g || jsonb_build_object('code', 'arrears', 'label', 'Owner in arrears', 'action', 'Collect the overdue owner invoice', 'who', 'owner');
  end if;
  return g;
end $$;

-- What is still open on a car, none of it in the way of the listing: stage 'handover' (the car is not released before
-- it is done), 'paperwork' (tracked), 'listing' (filled in by default or by the writer).
create or replace function app.vehicle_listing_warnings(p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  l vehicle_listings;
  ob vehicle_onboardings;
  w jsonb := '[]'::jsonb;
  c record;
  v_spec text[];
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null or v.retired_at is not null then return w; end if;
  select * into l from vehicle_listings where vehicle_id = v.id;
  if v.supply_type = 'program_owner' and v.management_mode <> 'turo_only' and not coalesce(v.on_fleet_policy, false) then
    w := w || jsonb_build_object('code', 'fleet_policy', 'stage', 'handover', 'label', 'Not on the fleet insurance policy yet',
                                 'action', 'File the insurer''s confirmation (the onboarding step). The car can be listed and booked; it is not handed over before then',
                                 'who', 'carmacars');
  end if;
  if v.status = 'onboarding' then
    select * into ob from vehicle_onboardings where vehicle_id = v.id;
    if ob.id is null then
      w := w || jsonb_build_object('code', 'onboarding', 'stage', 'paperwork', 'label', 'Onboarding not started', 'action', 'Approve the car under Applications', 'who', 'carmacars');
    else
      for c in select * from app.onboarding_checklist(v.id) x where x.status = 'open' and x.code not in ('photos', 'listing') order by x.sort_order loop
        w := w || jsonb_build_object('code', c.code, 'stage', 'paperwork', 'label', c.label, 'action', c.next_action, 'who', c.waits_on);
      end loop;
    end if;
  end if;
  if not exists (select 1 from rate_cards rc where rc.vehicle_id = v.id and rc.effective_from <= now() and (rc.effective_to is null or rc.effective_to > now())) then
    w := w || jsonb_build_object('code', 'rates', 'stage', 'listing', 'label', 'No rates yet', 'action', 'Publishing sets them from similar cars; change them on the Rates tab', 'who', 'carmacars');
  end if;
  v_spec := app.listing_spec_warnings(v.id);
  if cardinality(v_spec) > 0 then
    w := w || jsonb_build_object('code', 'details', 'stage', 'listing', 'label', 'Details by default: ' || lower(array_to_string(v_spec, ', ')),
                                 'action', 'Check them on the car (seats 5, automatic, unless entered)', 'who', 'carmacars');
  end if;
  if app.vehicle_uses_sample_photos(v.id) then
    w := w || jsonb_build_object('code', 'photos', 'stage', 'listing', 'label', 'Using sample photos', 'action', 'Real photos replace them once approved', 'who', 'carmacars');
  end if;
  if l.id is not null and (l.needs_rewrite or cardinality(app.listing_copy_problems(l.headline, l.description, l.features, l.faq)) > 0) then
    w := w || jsonb_build_object('code', 'copy', 'stage', 'listing', 'label', 'Copy being written', 'action', 'Written automatically; edit it under Listings if you want', 'who', 'carmacars');
  end if;
  if exists (select 1 from listing_similarity_flags x where x.vehicle_id = v.id and x.status = 'open') then
    w := w || jsonb_build_object('code', 'similar', 'stage', 'listing', 'label', 'Similar car on file', 'action', 'Look at it under Admin > Similar cars', 'who', 'carmacars');
  end if;
  return w;
end $$;

create or replace function app.cars_not_public() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('vehicle_id', x.id, 'name', app.vehicle_name(x.id), 'status', x.status, 'gates', x.gates,
                                               'next', x.gates -> 0 ->> 'action', 'sample_photos', app.vehicle_uses_sample_photos(x.id),
                                               'warnings', app.vehicle_listing_warnings(x.id))
                            order by x.created_at), '[]'::jsonb)
    from (select v.*, app.vehicle_public_gates(v.id) as gates from vehicles v
           where not v.is_sample and v.retired_at is null and v.status not in ('exited', 'total_loss', 'declined')
             and v.management_mode <> 'turo_only'
             and not exists (select 1 from public_vehicle_listings p where p.vehicle_id = v.id)) x
$$;

-- ================================================================ 3. the handover: on the fleet policy first
create or replace function app.vehicle_on_policy(p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select v.supply_type <> 'program_owner' or v.management_mode = 'turo_only' or v.on_fleet_policy from vehicles v where v.id = p_vehicle), false)
$$;

alter function app.booking_readiness(uuid) rename to booking_readiness_pre0070;
create or replace function app.booking_readiness(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r jsonb := app.booking_readiness_pre0070(p_booking);
  b bookings;
  v_ok boolean;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null or r is null then return r; end if;
  v_ok := b.booking_type = 'owner' or app.vehicle_on_policy(b.vehicle_id);
  if not v_ok then
    r := r || jsonb_build_object('missing', coalesce(r -> 'missing', '[]'::jsonb) || '["fleet_policy"]'::jsonb, 'ready_for_handover', false);
  end if;
  return r || jsonb_build_object('vehicle_on_policy', v_ok);
end $$;

alter function app.complete_handover(uuid, uuid, jsonb, uuid, timestamptz) rename to complete_handover_pre0070;
create or replace function app.complete_handover(p_booking uuid, p_by uuid, p_report jsonb default '{}'::jsonb,
    p_job uuid default null, p_now timestamptz default now())
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v vehicles;
begin
  select * into b from bookings where id = p_booking;
  if b.id is not null and b.booking_type <> 'owner' then
    select * into v from vehicles where id = b.vehicle_id for update;
    if not app.vehicle_on_policy(v.id) then
      raise exception 'Do not release the car: % is not on the fleet insurance policy yet. File the insurer''s confirmation first (the car''s onboarding)',
        app.vehicle_name(v.id) using errcode = '23514';
    end if;
    -- a car listed before its enrollment is released once it is on the policy
    if v.status in ('onboarding', 'ready_to_list') then
      update vehicles set status = 'available' where id = v.id;
    end if;
  end if;
  return app.complete_handover_pre0070(p_booking, p_by, p_report, p_job, p_now);
end $$;

-- ================================================================ 4. coverage: option 2 by the paid credit card, option 1 in full
alter table coverage_proofs
  add column if not exists renter_confirmed_at timestamptz,
  add column if not exists renter_confirmation_text text check (length(renter_confirmation_text) <= 1000),
  add column if not exists card_funding text check (card_funding in ('credit', 'debit', 'prepaid', 'unknown')),
  add column if not exists payment_method_id uuid references payment_methods (id),
  add column if not exists auto_confirmed boolean not null default false;
comment on column coverage_proofs.renter_confirmed_at is 'Option 2: the renter confirmed that the card they pay with carries rental car coverage (0070)';
comment on column coverage_proofs.auto_confirmed is 'Option 2 confirmed by the database: the booking was paid with a credit card and the renter confirmed its coverage (0070)';

-- The renter's wording, kept with the confirmation.
create or replace function app.coverage_card_wording() returns text language sql immutable as $$
  select 'I confirm that the credit card I pay this booking with includes rental car damage coverage (collision and loss) for this car and every driver, and that I decline the CarmaCars Protection Plan. If the card''s coverage does not apply, I am responsible for damage to the car under the rental agreement.'::text
$$;

-- Option 2 confirms itself when the renter confirmed and the booking's card is a credit card. Returns the state.
create or replace function app.coverage_card_try_confirm(p_booking uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  cp coverage_proofs;
  pm payment_methods;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null or b.coverage_option is distinct from 2 then return jsonb_build_object('state', 'not_option_2'); end if;
  select * into cp from coverage_proofs where booking_id = b.id and coverage_option = 2 and renter_confirmed_at is not null
   order by created_at desc limit 1 for update;
  if cp.id is null then return jsonb_build_object('state', 'awaiting_renter'); end if;
  if cp.status = 'confirmed' then return jsonb_build_object('state', 'confirmed'); end if;
  select * into pm from payment_methods where id = b.card_on_file_id;
  if pm.id is null then return jsonb_build_object('state', 'awaiting_payment'); end if;
  if not coalesce(pm.is_credit, false) then
    update coverage_proofs set card_funding = 'debit', payment_method_id = pm.id, card_last4 = pm.card_last4 where id = cp.id;
    return jsonb_build_object('state', 'not_credit');
  end if;
  update coverage_proofs
     set card_funding = 'credit', payment_method_id = pm.id, card_last4 = pm.card_last4,
         card_issuer = coalesce(nullif(btrim(card_issuer), ''), initcap(pm.card_brand), 'Card'),
         status = 'confirmed', confirmed_at = now(), covers_vehicle_and_drivers = true, auto_confirmed = true, rejection_reason = null
   where id = cp.id;
  update bookings set coverage_confirmed_at = now() where id = b.id and coverage_confirmed_at is null;
  perform app.log_booking_event(b.id, 'verification', b.status::text, b.status::text, null,
    'Coverage option 2 confirmed: paid with a credit card ending ' || pm.card_last4 || ', the renter confirmed its rental coverage', null, 'system',
    jsonb_build_object('coverage_proof_id', cp.id));
  return jsonb_build_object('state', 'confirmed');
end $$;

-- The renter confirms the card's rental coverage (the booking page). p: {issuer (optional)}.
create or replace function public.renter_coverage_card_confirm(p_booking uuid, p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  cp coverage_proofs;
begin
  perform app.assert_booking_renter(p_booking, p_by);
  select * into b from bookings where id = p_booking for update;
  if b.coverage_option is distinct from 2 then
    raise exception 'This booking''s coverage is not the credit card option' using errcode = '23514';
  end if;
  if b.status not in ('offered', 'pending_payment', 'confirmed') then
    raise exception 'Booking % is %: coverage is confirmed between the offer and pickup', b.booking_number, b.status using errcode = '23514';
  end if;
  select * into cp from coverage_proofs where booking_id = b.id and coverage_option = 2 order by created_at desc limit 1 for update;
  if cp.id is null or cp.status in ('rejected', 'lapsed') then
    insert into coverage_proofs (booking_id, coverage_option, status, card_issuer)
    values (b.id, 2, 'submitted', nullif(btrim(coalesce(p ->> 'issuer', '')), ''))
    returning * into cp;
  end if;
  update coverage_proofs
     set renter_confirmed_at = now(), renter_confirmation_text = app.coverage_card_wording(),
         card_issuer = coalesce(nullif(btrim(coalesce(p ->> 'issuer', '')), ''), card_issuer)
   where id = cp.id;
  return app.coverage_card_try_confirm(b.id) || jsonb_build_object('ok', true);
end $$;

-- The card saved at payment confirms option 2 at once when the renter already confirmed.
create or replace function app.bookings_coverage_card_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.coverage_option = 2 and new.card_on_file_id is not null and new.card_on_file_id is distinct from old.card_on_file_id then
    perform app.coverage_card_try_confirm(new.id);
  end if;
  return null;
end $$;
create trigger bookings_coverage_card_after after update of card_on_file_id on bookings
  for each row execute function app.bookings_coverage_card_after();

-- Option 1: the insurer, the policy number and the expiry come with the document (an expiry before the return is refused
-- by the upload itself, 0019).
alter function app.register_verification_upload(uuid, uuid, text, uuid, text, text, text, jsonb, text) rename to register_verification_upload_pre0070;
create or replace function app.register_verification_upload(p_booking uuid, p_by uuid, p_kind text, p_driver uuid, p_storage_path text,
                                                            p_sha256 text default null, p_mime_type text default null,
                                                            p_details jsonb default null, p_storage_bucket text default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  d jsonb := coalesce(p_details, '{}'::jsonb);
  b bookings;
  v_id uuid;
begin
  if p_kind = 'coverage_proof' then
    select * into b from bookings where id = p_booking;
    if coalesce(nullif(d ->> 'coverage_option', '')::integer, b.coverage_option) = 1 then
      if nullif(btrim(coalesce(d ->> 'insurer_name', '')), '') is null or nullif(btrim(coalesce(d ->> 'policy_number', '')), '') is null
         or nullif(btrim(coalesce(d ->> 'policy_expiry', '')), '') is null then
        raise exception 'Enter the insurer, the policy number and the policy expiry with the OPCF 27 document' using errcode = '22023';
      end if;
    end if;
  end if;
  v_id := app.register_verification_upload_pre0070(p_booking, p_by, p_kind, p_driver, p_storage_path, p_sha256, p_mime_type, p_details, p_storage_bucket);
  -- an optional benefits certificate for option 2 keeps the confirmation already given
  if p_kind = 'coverage_proof' then
    perform app.coverage_card_try_confirm(p_booking);
  end if;
  return v_id;
end $$;

-- What staff see for the coverage of one booking.
create or replace function app.coverage_detail(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'option', b.coverage_option, 'confirmed_at', b.coverage_confirmed_at,
    'paid_card', (select jsonb_build_object('brand', pm.card_brand, 'last4', pm.card_last4, 'credit', pm.is_credit) from payment_methods pm where pm.id = b.card_on_file_id),
    'proofs', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'status', c.status, 'insurer_name', c.insurer_name, 'policy_number', c.policy_number,
                          'policy_expiry', c.policy_expiry, 'card_issuer', c.card_issuer, 'card_last4', c.card_last4, 'card_funding', c.card_funding,
                          'renter_confirmed_at', c.renter_confirmed_at, 'renter_confirmation_text', c.renter_confirmation_text,
                          'auto_confirmed', c.auto_confirmed, 'confirmed_at', c.confirmed_at, 'rejection_reason', c.rejection_reason,
                          'document', c.proof_document_id is not null) order by c.created_at desc)
                        from coverage_proofs c where c.booking_id = b.id), '[]'::jsonb),
    'fleet_policy', app.vehicle_on_policy(b.vehicle_id))
    from bookings b where b.id = p_booking
$$;

-- The renter's own view of option 2 (the booking page).
create or replace function public.renter_coverage_state(p_booking uuid, p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.assert_booking_renter(p_booking, p_by);
  return (select jsonb_build_object('option', b.coverage_option, 'confirmed', b.coverage_confirmed_at is not null,
                                    'wording', app.coverage_card_wording(),
                                    'renter_confirmed', exists (select 1 from coverage_proofs c where c.booking_id = b.id and c.coverage_option = 2 and c.renter_confirmed_at is not null),
                                    'paid_card', (select jsonb_build_object('brand', pm.card_brand, 'last4', pm.card_last4, 'credit', pm.is_credit) from payment_methods pm where pm.id = b.card_on_file_id))
            from bookings b where b.id = p_booking);
end $$;

-- ================================================================ 5. the doors
create or replace function app.ops70(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'ops_read' and p_name = 'vehicle_listing_warnings' then
    if not (app.user_is_admin(p_user) or app.user_va_has(p_user, 'cs', 'fleet')) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return jsonb_build_object('warnings', app.vehicle_listing_warnings(nullif(p ->> 'vehicle_id', '')::uuid),
                              'gates', app.vehicle_public_gates(nullif(p ->> 'vehicle_id', '')::uuid));
  end if;
  raise exception 'Unknown read %', p_name using errcode = '22023';
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0070;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb;
begin
  if p_call = 'ops_read' and p_name = 'vehicle_listing_warnings' then
    perform app.door_begin(p_user, p_aal);
    return app.ops70(p_user, p_call, p_name, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  r := app.door_pre0070(p_user, p_aal, p_call, p_name, p);
  -- the identity review shows the coverage in full (option, paid card, the renter's confirmation, proofs)
  if p_call = 'va_read' and p_name = 'verification' and r ? 'booking_id' then
    r := r || jsonb_build_object('coverage', app.coverage_detail((r ->> 'booking_id')::uuid));
  end if;
  return r;
end $$;

create or replace function app.schema_marker() returns text
language plpgsql stable security definer set search_path = public, app as $$
declare v text;
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    begin
      execute $q$select max(version) from supabase_migrations.schema_migrations where version ~ '^\d{4}$'$q$ into v;
    exception when others then v := null;
    end;
  end if;
  return greatest(coalesce(v, '0070'), '0070');
end $$;

-- a wrapper gets the privileges of the function it wraps; the new functions are for the server only
do $$
declare
  r record;
  v_new regprocedure;
  g text;
  f record;
begin
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('booking_readiness_pre0070', 'booking_readiness'), ('complete_handover_pre0070', 'complete_handover'),
                          ('register_verification_upload_pre0070', 'register_verification_upload'), ('door_pre0070', 'door')) m(old_name, new_name)
               on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    execute format('revoke all on function %s from public, anon, authenticated', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['listing_spec_warnings', 'listing_default_rates', 'listing_fill_defaults',
              'vehicles_keep_live_status', 'bookings_default_share', 'vehicle_listing_warnings', 'vehicle_on_policy', 'coverage_card_wording',
              'coverage_card_try_confirm', 'bookings_coverage_card_after', 'coverage_detail', 'ops70'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
revoke all on function public.renter_coverage_card_confirm(uuid, uuid, jsonb), public.renter_coverage_state(uuid, uuid) from public, anon, authenticated;
grant execute on function public.renter_coverage_card_confirm(uuid, uuid, jsonb), public.renter_coverage_state(uuid, uuid) to service_role;
