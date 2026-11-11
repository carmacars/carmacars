-- 1305_r35a_rewards_photo_rebook.sql
-- Release 35, part A (helper A), task 9 (docs/changes/2026-11-11-r35a-request-offers.md). The owner: two more ways to earn
-- reward points. review_photo: a review on carmacars.ca with at least one photo, 100 points on top of the review's own,
-- once per rental. rebook: 150 points for every completed rental after the first (booking again).
--   1. reviews.photos: the renter's photos with their review (up to 6, private storage keys under the booking), set by
--      public.server_review_photos_set (the renter of the booking, on their own review).
--   2. A review with a photo, on a returned or closed rental, earns review_photo once per rental (source review_photo:<booking>).
--   3. A rental closing when the renter already has a completed rental earns rebook (source rebook:<booking>); the first
--      rental keeps first_rental. Owner trips earn nothing (as before).
--   4. The renter's Rewards page lists every earning action that is on (the follows, the reviews, Google and the referral
--      included), not only those whose link is set; Google's review link falls back to the business's place id (as the
--      review page does), so "Review us on Google" shows whenever either is set.
-- Both actions are rows of reward_actions (points and on or off on Admin > Rewards) and show on the renter's Rewards page with
-- the others. No applied migration is edited.
set local check_function_bodies = off;

insert into reward_actions (code, label, detail, points, limit_text, sort) values
  ('review_photo', 'Add a photo to your review', 'A review on carmacars.ca with at least one photo of your trip, on top of the review''s points.', 100, 'Each rental, once', 7),
  ('rebook', 'Book with us again', 'Every completed rental after your first.', 150, 'Every rental after the first', 3)
on conflict (code) do nothing;

alter table reviews add column if not exists photos jsonb not null default '[]'::jsonb;
alter table reviews add constraint reviews_photos_shape check (jsonb_typeof(photos) = 'array' and jsonb_array_length(photos) <= 6);
comment on column reviews.photos is 'The renter''s photos with the review (1305): [{bucket, path}], private storage keys under bookings/<booking>/review/. One or more earns review_photo once per rental.';

-- the renter's photos on their own review: p_photos [{bucket, path}]
create function public.server_review_photos_set(p_booking uuid, p_by uuid, p_photos jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_review uuid;
  v_clean jsonb;
begin
  if p_by is null or not app.is_booking_renter(p_booking, p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select id into v_review from reviews where booking_id = p_booking order by created_at desc limit 1;
  if v_review is null then raise exception 'Send your review first' using errcode = 'P0002'; end if;
  if jsonb_typeof(coalesce(p_photos, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_photos, '[]'::jsonb)) > 6 then
    raise exception 'Up to 6 photos' using errcode = '22023';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('bucket', 'condition-photos', 'path', x ->> 'path')), '[]'::jsonb) into v_clean
    from jsonb_array_elements(coalesce(p_photos, '[]'::jsonb)) x;
  if exists (select 1 from jsonb_array_elements(v_clean) x where (x ->> 'path') not like 'bookings/' || p_booking || '/review/%' or (x ->> 'path') like '%..%') then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  update reviews set photos = v_clean where id = v_review;
  return jsonb_build_object('ok', true, 'photos', jsonb_array_length(v_clean),
    'points', coalesce((select points from reward_ledger where source_key = 'review_photo:' || p_booking and kind = 'earn' and reversed_at is null), 0));
end $$;

create function app.rewards_review_photo_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if jsonb_array_length(coalesce(new.photos, '[]'::jsonb)) >= 1
     and exists (select 1 from bookings b where b.id = new.booking_id and b.status in ('returned', 'closed') and b.booking_type <> 'owner') then
    perform app.rewards_award(new.renter_id, 'review_photo', 'review_photo:' || new.booking_id, null, new.booking_id, 'Photo with your review on carmacars.ca');
  end if;
  return null;
end $$;
create trigger reviews_rewards_photo after insert or update of photos on reviews for each row execute function app.rewards_review_photo_after();

-- booking again: every completed rental after the first
alter function app.rewards_on_close(uuid) rename to rewards_on_close_pre1305;
create function app.rewards_on_close(p_booking uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  n jsonb := app.rewards_on_close_pre1305(p_booking);
  b bookings;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null or b.renter_id is null or b.status <> 'closed' or b.booking_type = 'owner' or not (app.rewards()).enabled then return n; end if;
  if exists (select 1 from bookings x where x.renter_id = b.renter_id and x.status = 'closed' and x.id <> b.id and x.booking_type <> 'owner') then
    n := coalesce(n, '{}'::jsonb) || jsonb_build_object('rebook', app.rewards_award(b.renter_id, 'rebook', 'rebook:' || b.id, null, b.id, 'Booked with us again: ' || b.booking_number));
  end if;
  return n;
end $$;

-- the Rewards page: every action that is on, and Google from the place id when no review link is set
alter function app.rewards_state(uuid) rename to rewards_state_pre1305;
create function app.rewards_state(p_renter uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := app.rewards_state_pre1305(p_renter);
  v_place text := (select nullif(btrim(coalesce(google_place_id, '')), '') from site_settings limit 1);
begin
  if p_renter is null or v is null then return v; end if;
  v := jsonb_set(v, '{actions}', (select coalesce(jsonb_agg(jsonb_build_object('code', x.code, 'label', x.label, 'detail', x.detail, 'points', x.points, 'limit', x.limit_text) order by x.sort, x.code), '[]'::jsonb)
                                    from reward_actions x where x.enabled));
  if (v -> 'google') is null or v -> 'google' = 'null'::jsonb then
    if v_place is not null and (app.rewards_action('review_google')).code is not null then
      v := jsonb_set(v, '{google}', jsonb_build_object('url', 'https://search.google.com/local/writereview?placeid=' || v_place, 'points', (app.rewards_action('review_google')).points,
        'bookings', (select coalesce(jsonb_agg(jsonb_build_object('number', b.booking_number, 'vehicle', app.vehicle_name(b.vehicle_id), 'returned', app.local_date(b.return_at),
                       'claimed', exists (select 1 from reward_ledger l where l.source_key = 'review_google:' || b.id)) order by b.return_at desc), '[]'::jsonb)
                     from bookings b where b.renter_id = p_renter and b.status in ('returned', 'closed') and b.booking_type <> 'owner' and b.return_at > now() - interval '12 months')));
    end if;
  end if;
  return v;
end $$;

do $$
declare
  f record;
  g text;
begin
  -- the new rewards_on_close keeps the grants the old one had
  execute 'revoke all on function app.rewards_on_close(uuid) from public, anon, authenticated';
  execute 'revoke all on function app.rewards_state(uuid) from public, anon, authenticated';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.rewards_state_pre1305(uuid)', 'execute') then execute format('grant execute on function app.rewards_state(uuid) to %I', g); end if;
  end loop;
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.rewards_on_close_pre1305(uuid)', 'execute') then execute format('grant execute on function app.rewards_on_close(uuid) to %I', g); end if;
  end loop;
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['rewards_on_close_pre1305', 'rewards_review_photo_after', 'rewards_state_pre1305']))
        or (n.nspname = 'public' and p.proname = 'server_review_photos_set')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
