-- 0054_admin_access_samples_applications.sql
-- The owner's requests of October 16, 2026 (docs/changes/2026-10-16-legal-review-admin-redesign.md):
--   1. admin access only through the addresses in site_settings.admin_allowed_emails (rent@carmacars.ca), plus the
--      automated test account of the live verification (site_settings.admin_test_emails: verify-admin@carmacars.ca);
--      the Admin role is refused in the database for any other address
--   2. a car listed without real photos shows sample photos: a library staff fill in Admin > Settings > Sample photos
--      (per make and model, make, or body type) and a built-in placeholder per body type; marked "Sample photo" on the
--      site; real photos replace them automatically; the plate check does not apply to them
--   3. the simpler admin portal: one "To do" list with counts, and a search across bookings, cars, owners, partners and
--      renters
--   4. the owner applications inbox: status, checks, notes, ask for something, approve, decline
-- No applied migration is edited. Functions changed are wrapped (renamed _00NN and called from a new function of the
-- same name).

-- ================================================================ 1. admin access
alter table site_settings add column if not exists admin_allowed_emails text[] not null default array['rent@carmacars.ca']::text[];
alter table site_settings add column if not exists admin_test_emails text[] not null default array['verify-admin@carmacars.ca']::text[];
comment on column site_settings.admin_allowed_emails is
  'The only addresses that may hold the Admin role (0054). Edited in Admin > Settings > Staff and roles > Admin access.';
comment on column site_settings.admin_test_emails is
  'The automated test account of the live verification (verify workflow, web/scripts/verify-live.mjs): verify-admin@carmacars.ca, on the email suppression list, its password scrambled after each run. Allowed the Admin role beside admin_allowed_emails (0054).';
update site_settings set admin_allowed_emails = array['rent@carmacars.ca']::text[] where singleton and admin_allowed_emails is distinct from array['rent@carmacars.ca']::text[] and cardinality(admin_allowed_emails) = 0;

-- An address may hold the Admin role when it is in the list, or is the test account. Addresses on example.test (a
-- domain reserved for tests that never receives email, RFC 6761) are the local stack's and the database tests' accounts.
create or replace function app.admin_email_allowed(p_email text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce(lower(btrim(p_email)) = any (select lower(btrim(x)) from site_settings s, unnest(s.admin_allowed_emails || s.admin_test_emails) x where s.singleton), false)
      or coalesce(lower(btrim(p_email)) like '%@example.test', false)
$$;

create or replace function app.user_roles_admin_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_email text := (select u.email from users u where u.id = new.user_id);
begin
  if new.role = 'admin' and not app.admin_email_allowed(v_email) then
    raise exception 'Admin access is only for % (Admin > Settings > Staff and roles > Admin access). % cannot be an Admin.',
      (select array_to_string(admin_allowed_emails, ', ') from site_settings where singleton), coalesce(v_email, 'This account') using errcode = '42501';
  end if;
  return new;
end $$;
create trigger user_roles_admin_guard before insert or update on user_roles for each row execute function app.user_roles_admin_guard();

create or replace function app.users_admin_email_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.email is distinct from old.email and exists (select 1 from user_roles r where r.user_id = new.id and r.role = 'admin')
     and not app.admin_email_allowed(new.email) then
    raise exception 'An Admin''s address stays one of the Admin access addresses' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger users_admin_email_guard before update of email on users for each row execute function app.users_admin_email_guard();

create or replace function app.admin_access_read(p_admin uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_admin);
  return (select jsonb_build_object('allowed', to_jsonb(s.admin_allowed_emails), 'test', to_jsonb(s.admin_test_emails),
           'holders', (select coalesce(jsonb_agg(jsonb_build_object('email', u.email, 'name', u.full_name, 'status', u.status,
                                                                    'allowed', app.admin_email_allowed(u.email),
                                                                    'test', lower(u.email) = any (select lower(x) from unnest(s.admin_test_emails) x)) order by u.email), '[]'::jsonb)
                         from user_roles r join users u on u.id = r.user_id where r.role = 'admin'))
    from site_settings s where s.singleton);
end $$;

create or replace function app.admin_access_save(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_list text[];
  v_before text[];
  e text;
begin
  perform app.assert_admin(p_admin);
  select array_agg(distinct lower(btrim(x))) into v_list from jsonb_array_elements_text(coalesce(p -> 'emails', '[]'::jsonb)) x where btrim(x) <> '';
  if v_list is null or cardinality(v_list) = 0 then raise exception 'Keep at least one Admin address' using errcode = '22023'; end if;
  foreach e in array v_list loop
    if e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception '% is not an email address', e using errcode = '22023'; end if;
  end loop;
  if exists (select 1 from user_roles r join users u on u.id = r.user_id, site_settings s
              where s.singleton and r.role = 'admin' and not (lower(u.email) = any (v_list)) and not (lower(u.email) = any (select lower(x) from unnest(s.admin_test_emails) x))
                and lower(u.email) not like '%@example.test') then
    raise exception 'An address that holds the Admin role stays on the list: end that person''s Admin access first' using errcode = '23514';
  end if;
  select admin_allowed_emails into v_before from site_settings where singleton;
  update site_settings set admin_allowed_emails = v_list where singleton;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_admin, 'admin_access_save', 'site_settings', 'admin_allowed_emails', jsonb_build_object('emails', v_before), jsonb_build_object('emails', v_list));
  return app.admin_access_read(p_admin);
end $$;

-- ================================================================ 2. sample photos
create table sample_photos (
  id           uuid primary key default gen_random_uuid(),
  body_type    text check (body_type is null or body_type in ('sedan', 'suv', 'truck', 'van', 'coupe', 'hatchback', 'ev')),
  make         text check (make is null or length(btrim(make)) between 1 and 60),
  model        text check (model is null or length(btrim(model)) between 1 and 80),
  storage_path text not null check (storage_path ~ '^samples/[A-Za-z0-9._/-]+$'),
  alt          text not null check (length(btrim(alt)) between 3 and 200),
  width        integer check (width is null or width between 100 and 8000),
  height       integer check (height is null or height between 100 and 8000),
  sort_order   integer not null default 0,
  active       boolean not null default true,
  uploaded_by  uuid references users (id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check (body_type is not null or make is not null),
  check (model is null or make is not null)
);
create index sample_photos_match_idx on sample_photos (lower(make), lower(model), body_type) where active;
create trigger sample_photos_updated before update on sample_photos for each row execute function app.set_updated_at();
comment on table sample_photos is 'Stock photos shown on a listing that has no real photos yet (0054), per make and model, make, or body type. Marked "Sample photo" on the site.';
alter table sample_photos enable row level security;
create policy admin_all on sample_photos for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on sample_photos from anon, authenticated;
grant select on sample_photos to authenticated;
grant all on sample_photos to service_role;

-- The body type a car's sample photos are chosen by: the listing's body style, the car's, or the VIN decode's; an
-- electric car shows the EV placeholder.
create or replace function app.sample_body_key(p_vehicle uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case
    when v.fuel::text = 'electric' then 'ev'
    when b ~* 'pick.?up|truck' then 'truck'
    when b ~* 'van|minivan|cargo' then 'van'
    when b ~* 'suv|sport utility|crossover|mpv|multi.?purpose' then 'suv'
    when b ~* 'coupe|convertible|cabriolet|roadster' then 'coupe'
    when b ~* 'hatch|liftback|wagon' then 'hatchback'
    else 'sedan' end
    from vehicles v
    left join vehicle_listings l on l.vehicle_id = v.id
    cross join lateral (select coalesce(nullif(l.body_style, ''), nullif(v.body_type, ''),
                                        (select d.body_class from vin_decodes d where upper(d.vin) = upper(v.vin) and d.ok order by d.decoded_at desc limit 1), '') as b) x
   where v.id = p_vehicle
$$;

create or replace function app.sample_body_label(p_key text) returns text
language sql immutable as $$
  select case p_key when 'suv' then 'SUV' when 'ev' then 'electric car' when 'truck' then 'pickup truck' when 'van' then 'van'
                    when 'coupe' then 'coupe' when 'hatchback' then 'hatchback' else 'sedan' end
$$;

-- A car uses sample photos while it has no real photo approved and processed.
create or replace function app.vehicle_uses_sample_photos(p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select not exists (select 1 from vehicle_photos ph where ph.vehicle_id = p_vehicle and ph.replaced_at is null and ph.status = 'approved'
                       and ph.processed_path is not null)
$$;

-- The sample photos of a car: the library's photos for its make and model, else its make and body type, else its body
-- type, else the built-in placeholder of its body type (a static asset of the site).
create or replace function app.vehicle_sample_photos(p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  k text := app.sample_body_key(p_vehicle);
  v_name text;
  v_out jsonb;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then return '[]'::jsonb; end if;
  v_name := concat_ws(' ', v.year::text, v.make, v.model);
  select jsonb_agg(jsonb_build_object('path', s.storage_path, 'alt', s.alt, 'width', s.width, 'height', s.height, 'shot', 'sample', 'label', 'Sample photo',
                                      'is_cover', s.rn = 1, 'sample', true) order by s.rn)
    into v_out
    from (select x.*, row_number() over (order by x.tier, x.sort_order, x.created_at) rn
            from (select p.*, case when p.model is not null then 1 when p.body_type is not null and p.make is not null then 2 when p.make is not null then 3 else 4 end tier
                    from sample_photos p
                   where p.active
                     and ((lower(p.make) = lower(v.make) and lower(p.model) = lower(v.model))
                          or (lower(p.make) = lower(v.make) and p.model is null and (p.body_type is null or p.body_type = k))
                          or (p.make is null and p.body_type = k))) x) s
   where s.tier = (select min(case when p.model is not null then 1 when p.body_type is not null and p.make is not null then 2 when p.make is not null then 3 else 4 end)
                     from sample_photos p where p.active
                      and ((lower(p.make) = lower(v.make) and lower(p.model) = lower(v.model))
                           or (lower(p.make) = lower(v.make) and p.model is null and (p.body_type is null or p.body_type = k))
                           or (p.make is null and p.body_type = k)))
     and s.rn <= 6;
  return coalesce(v_out, jsonb_build_array(jsonb_build_object('path', '/sample-photos/' || k || '.jpg', 'alt', format('Sample photo of a %s, not the %s itself', app.sample_body_label(k), v_name),
    'width', 1600, 'height', 1067, 'shot', 'sample', 'label', 'Sample photo', 'is_cover', true, 'sample', true, 'builtin', k)));
end $$;

-- Publishing without real photos: no shot is missing and no photo problem while the car uses sample photos (the
-- plate check of 0042 reads real photos only, so it does not apply to them). Once one real photo is approved, the
-- usual photo rules apply again.
-- An intake with no photo uploaded at all is submitted as it is (the copy is still drafted from the VIN decode and the
-- facts); with some photos, every required shot is needed as before (0022).
alter function app.submit_listing_intake(uuid, uuid) rename to submit_listing_intake_0022;
create or replace function app.submit_listing_intake(p_by uuid, p_intake uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  i listing_intakes;
begin
  select * into i from listing_intakes where id = p_intake for update;
  if i.id is null then raise exception 'Listing intake not found' using errcode = 'P0002'; end if;
  if i.submitted_at is not null or exists (select 1 from vehicle_photos ph where ph.vehicle_id = i.vehicle_id and ph.replaced_at is null and ph.status <> 'rejected') then
    return app.submit_listing_intake_0022(p_by, p_intake);
  end if;
  if p_by is null or not (app.user_may_list(p_by, i.vehicle_id, 'start') or app.user_may_list(p_by, i.vehicle_id, 'review')) then
    raise exception 'Not permitted' using errcode = '42501';
  end if;
  update listing_intakes set submitted_at = now(), notes = concat_ws(' ', notes, 'Submitted with no photos: the listing shows sample photos until real photos are added.') where id = i.id;
  perform app.enqueue_listing_job(i.id, 'draft_copy', null, jsonb_build_object('facts', app.listing_facts(i.vehicle_id), 'notes', i.notes));
  return jsonb_build_object('intake_id', i.id, 'state', app.advance_listing_intake(i.id), 'sample_photos', true);
end $$;

-- While publishing (app.publish_listing below names the car), a car with no real photo has no photo problem: it shows
-- sample photos. Elsewhere (the onboarding checklist, the review screen) the photos still read as to do.
alter function app.listing_photo_problems(uuid) rename to listing_photo_problems_0022;
create or replace function app.listing_photo_problems(p_vehicle uuid) returns text[]
language sql stable security definer set search_path = public, app as $$
  select case when coalesce(current_setting('app.sample_photos_ok', true), '') = p_vehicle::text and app.vehicle_uses_sample_photos(p_vehicle)
              then '{}'::text[] else app.listing_photo_problems_0022(p_vehicle) end
$$;
alter function app.publish_listing(uuid, uuid) rename to publish_listing_0042;
create or replace function app.publish_listing(p_vehicle uuid, p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb;
begin
  perform set_config('app.sample_photos_ok', p_vehicle::text, true);
  v_out := app.publish_listing_0042(p_vehicle, p_by);
  perform set_config('app.sample_photos_ok', '', true);
  return v_out || jsonb_build_object('sample_photos', app.vehicle_uses_sample_photos(p_vehicle));
exception when others then
  perform set_config('app.sample_photos_ok', '', true);
  raise;
end $$;

-- The site: the real photos, or the sample photos while there are none.
alter function app.public_listing_photos(uuid) rename to public_listing_photos_0022;
create or replace function app.public_listing_photos(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when jsonb_array_length(app.public_listing_photos_0022(p_vehicle)) > 0 then app.public_listing_photos_0022(p_vehicle)
              else app.vehicle_sample_photos(p_vehicle) end
$$;
alter function app.public_listing_row(uuid) rename to public_listing_row_0022;
create or replace function app.public_listing_row(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when r is null then null
              when r -> 'cover' is null or r -> 'cover' = 'null'::jsonb
                then r || jsonb_build_object('cover', app.vehicle_sample_photos(p_vehicle) -> 0, 'sample_photos', true)
              else r || jsonb_build_object('sample_photos', false) end
    from (select app.public_listing_row_0022(p_vehicle) r) x
$$;

-- Staff: which cars show sample photos now (the listing screens say "Using sample photos").
create or replace function app.vehicles_using_sample_photos() returns table (vehicle_id uuid, listing_status text, body_key text)
language sql stable security definer set search_path = public, app as $$
  select v.id, l.status, app.sample_body_key(v.id)
    from vehicles v left join vehicle_listings l on l.vehicle_id = v.id
   where v.status not in ('exited') and v.retired_at is null and v.management_mode <> 'turo_only' and app.vehicle_uses_sample_photos(v.id)
$$;

create or replace function app.sample_photos_read(p_admin uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_admin);
  return (select jsonb_build_object(
    'photos', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'body_type', p.body_type, 'make', p.make, 'model', p.model, 'path', p.storage_path,
                                                            'alt', p.alt, 'active', p.active, 'sort_order', p.sort_order, 'created_at', p.created_at)
                                         order by p.make nulls last, p.model nulls last, p.body_type, p.sort_order), '[]'::jsonb) from sample_photos p),
    'builtin', jsonb_build_array('sedan', 'suv', 'truck', 'van', 'coupe', 'hatchback', 'ev'),
    'using', (select coalesce(jsonb_agg(jsonb_build_object('vehicle_id', u.vehicle_id, 'vehicle', app.vehicle_name(u.vehicle_id), 'listing_status', u.listing_status,
                                                           'body_key', u.body_key, 'photos', app.vehicle_sample_photos(u.vehicle_id)) order by app.vehicle_name(u.vehicle_id)), '[]'::jsonb)
                from app.vehicles_using_sample_photos() u)));
end $$;

create or replace function app.sample_photo_save(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r sample_photos;
begin
  perform app.assert_admin(p_admin);
  if nullif(p ->> 'id', '') is not null then
    update sample_photos set active = coalesce((p ->> 'active')::boolean, active), alt = coalesce(nullif(btrim(p ->> 'alt'), ''), alt),
           sort_order = coalesce((p ->> 'sort_order')::integer, sort_order)
     where id = (p ->> 'id')::uuid returning * into r;
    if r.id is null then raise exception 'Sample photo not found' using errcode = 'P0002'; end if;
  else
    if nullif(btrim(coalesce(p ->> 'make', '')), '') is null and nullif(p ->> 'body_type', '') is null then
      raise exception 'Choose a body type, or a make (and a model)' using errcode = '22023';
    end if;
    insert into sample_photos (body_type, make, model, storage_path, alt, width, height, sort_order, uploaded_by)
    values (nullif(p ->> 'body_type', ''), nullif(btrim(p ->> 'make'), ''), nullif(btrim(p ->> 'model'), ''), p ->> 'path',
            coalesce(nullif(btrim(p ->> 'alt'), ''), concat_ws(' ', 'Sample photo of a', nullif(btrim(p ->> 'make'), ''), nullif(btrim(p ->> 'model'), ''),
                                                              case when nullif(btrim(p ->> 'make'), '') is null then app.sample_body_label(p ->> 'body_type') end)),
            nullif(p ->> 'width', '')::integer, nullif(p ->> 'height', '')::integer, coalesce((p ->> 'sort_order')::integer, 0), p_admin)
    returning * into r;
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_admin, 'sample_photo_save', 'sample_photos', r.id::text, to_jsonb(r));
  return to_jsonb(r);
end $$;

create or replace function app.sample_photo_delete(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r sample_photos;
begin
  perform app.assert_admin(p_admin);
  delete from sample_photos where id = (p ->> 'id')::uuid returning * into r;
  if r.id is null then raise exception 'Sample photo not found' using errcode = 'P0002'; end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before) values (p_admin, 'sample_photo_delete', 'sample_photos', r.id::text, to_jsonb(r));
  return jsonb_build_object('deleted', r.id, 'path', r.storage_path);
end $$;

-- ================================================================ 4. owner applications (before the To do list, which counts them)
alter table owner_applications add column if not exists status text not null default 'new';
alter table owner_applications add constraint owner_applications_status_check check (status in ('new', 'waiting_on_owner', 'approved', 'declined'));
alter table owner_applications add column if not exists checks jsonb not null default '{}'::jsonb;
alter table owner_applications add column if not exists requested_items text[] not null default '{}';
alter table owner_applications add column if not exists request_message text;
alter table owner_applications add column if not exists requested_at timestamptz;
alter table owner_applications add column if not exists owner_reply text;
alter table owner_applications add column if not exists owner_replied_at timestamptz;
alter table owner_applications add column if not exists decided_at timestamptz;
alter table owner_applications add column if not exists decided_by uuid references users (id);
alter table owner_applications add column if not exists decline_reason text;
alter table owner_applications add column if not exists updated_at timestamptz not null default now();
comment on column owner_applications.status is 'The inbox (0054): new, waiting_on_owner (staff asked for something), approved, declined.';
comment on column owner_applications.checks is 'licence, ownership, insurance, lender: {status: ok | problem | not_needed, note, by, at} (0054).';
drop trigger if exists owner_applications_updated on owner_applications;
create trigger owner_applications_updated before update on owner_applications for each row execute function app.set_updated_at();
-- the applications already on file: approved once their cars have terms or the owner is active, else new (nobody is
-- emailed by this migration)
update owner_applications a set status = 'approved', decided_at = coalesce(decided_at, now())
 where a.status = 'new' and (exists (select 1 from owners o where o.id = a.owner_id and o.status = 'active')
       or exists (select 1 from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id where v.owner_id = a.owner_id and ob.status <> 'intake'));

create table owner_application_notes (
  id             uuid primary key default gen_random_uuid(),
  application_id uuid not null references owner_applications (id) on delete cascade,
  body           text not null check (length(btrim(body)) between 1 and 4000),
  kind           text not null default 'note' check (kind in ('note', 'request', 'reply', 'decision')),
  created_by     uuid references users (id),
  created_at     timestamptz not null default now()
);
create index owner_application_notes_app_idx on owner_application_notes (application_id, created_at);
comment on table owner_application_notes is 'Staff notes on an owner application, and the requests and replies of the inbox (0054).';
alter table owner_application_notes enable row level security;
create policy admin_all on owner_application_notes for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on owner_application_notes from anon, authenticated;
grant select on owner_application_notes to authenticated;
grant all on owner_application_notes to service_role;

-- What staff may ask for, in words the owner reads.
create or replace function app.application_request_items() returns jsonb
language sql immutable as $$
  select jsonb_build_array(
    jsonb_build_object('code', 'licence', 'label', 'A photo of your driver''s licence, front and back'),
    jsonb_build_object('code', 'ownership', 'label', 'The vehicle''s ownership permit'),
    jsonb_build_object('code', 'insurance', 'label', 'Your current insurance pink slip'),
    jsonb_build_object('code', 'lender', 'label', 'Your lender''s or lessor''s written permission'),
    jsonb_build_object('code', 'vin', 'label', 'The VIN, checked against the car'),
    jsonb_build_object('code', 'photos', 'label', 'Photos of the car'),
    jsonb_build_object('code', 'corporation', 'label', 'Your corporation''s articles and number'),
    jsonb_build_object('code', 'other', 'label', 'Something else (see the message)'))
$$;

create or replace function app.application_view(p_admin uuid, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  a owner_applications;
  o owners;
begin
  perform app.assert_admin(p_admin);
  select * into a from owner_applications where id = p_id;
  if a.id is null then raise exception 'Application not found' using errcode = 'P0002'; end if;
  select * into o from owners where id = a.owner_id;
  return jsonb_build_object(
    'application', to_jsonb(a),
    'owner', jsonb_build_object('id', o.id, 'legal_name', o.legal_name, 'owner_type', o.owner_type, 'corporation_name', o.corporation_name,
              'corporation_number', o.corporation_number, 'email', o.email, 'phone', o.phone, 'status', o.status, 'is_test', o.is_test,
              'address', concat_ws(', ', nullif(o.address_line1, ''), nullif(o.address_line2, ''), nullif(o.city, ''), nullif(o.province, ''), nullif(o.postal_code, '')),
              'has_account', o.user_id is not null,
              'licence_number', (select p.licence_number from owner_private_details p where p.owner_id = o.id),
              'licence_province', (select p.licence_province from owner_private_details p where p.owner_id = o.id),
              'date_of_birth', (select p.date_of_birth from owner_private_details p where p.owner_id = o.id),
              'other_applications', (select coalesce(jsonb_agg(x.application_number order by x.created_at), '[]'::jsonb) from owner_applications x where x.owner_id = o.id and x.id <> a.id)),
    'vehicles', (select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'vin', v.vin, 'plate', v.plate, 'colour', v.colour,
                   'odometer_km', v.odometer_km, 'year', v.year, 'make', v.make, 'model', v.model, 'management_mode', v.management_mode,
                   'onboarding_status', ob.status, 'title_status', ob.title_status, 'finance_party_name', ob.finance_party_name,
                   'current_insurer', ob.current_insurer, 'proposed_onboarding_method', ob.proposed_onboarding_method, 'estimate_cents', ob.estimate_cents,
                   'decode', (select jsonb_build_object('ok', d.ok, 'year', d.year, 'make', d.make, 'model', d.model, 'trim', d.trim, 'body_class', d.body_class,
                                                        'fuel', d.fuel, 'drivetrain', d.drivetrain, 'error_code', d.error_code)
                                from vin_decodes d where upper(d.vin) = upper(v.vin) order by d.decoded_at desc limit 1)) order by v.created_at), '[]'::jsonb)
                   from vehicles v left join vehicle_onboardings ob on ob.vehicle_id = v.id where v.owner_id = o.id),
    'documents', (select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'title', d.title, 'vehicle', app.vehicle_name(d.vehicle_id),
                   'created_at', d.created_at) order by d.created_at desc), '[]'::jsonb)
                   from documents d where d.owner_id = o.id),
    'notes', (select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'kind', n.kind, 'body', n.body, 'at', n.created_at,
                'by', (select u.full_name from users u where u.id = n.created_by)) order by n.created_at), '[]'::jsonb)
                from owner_application_notes n where n.application_id = a.id),
    'invoices', (select coalesce(jsonb_agg(jsonb_build_object('invoice_number', i.invoice_number, 'kind', i.kind, 'status', i.status, 'total_cents', i.total_cents) order by i.created_at), '[]'::jsonb)
                   from owner_invoices i where i.owner_id = o.id),
    'items', app.application_request_items());
end $$;

create or replace function app.applications_list(p_admin uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_admin);
  return (select jsonb_build_object(
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'application_number', a.application_number, 'status', a.status, 'created_at', a.created_at,
              'owner', o.legal_name, 'email', o.email, 'owner_type', o.owner_type, 'is_test', o.is_test, 'source', a.source,
              'vehicles', (select coalesce(jsonb_agg(app.vehicle_name(v.id) order by v.created_at), '[]'::jsonb) from vehicles v where v.owner_id = o.id),
              'checks_done', (select count(*) from jsonb_each(a.checks) c where c.value ->> 'status' in ('ok', 'not_needed')),
              'requested_at', a.requested_at, 'owner_replied_at', a.owner_replied_at) order by a.created_at desc)
             from owner_applications a join owners o on o.id = a.owner_id
            where coalesce(nullif(p ->> 'status', ''), a.status) = a.status), '[]'::jsonb),
    'counts', (select jsonb_object_agg(s, (select count(*) from owner_applications x where x.status = s)) from unnest(array['new', 'waiting_on_owner', 'approved', 'declined']) s)));
end $$;

create or replace function app.application_check(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a owner_applications;
begin
  perform app.assert_admin(p_admin);
  if coalesce(p ->> 'check', '') not in ('licence', 'ownership', 'insurance', 'lender') then raise exception 'Unknown check' using errcode = '22023'; end if;
  if coalesce(p ->> 'status', '') not in ('ok', 'problem', 'not_needed', 'not_checked') then raise exception 'Unknown result' using errcode = '22023'; end if;
  update owner_applications set checks = case when p ->> 'status' = 'not_checked' then checks - (p ->> 'check')
        else checks || jsonb_build_object(p ->> 'check', jsonb_build_object('status', p ->> 'status', 'note', nullif(btrim(p ->> 'note'), ''), 'by', p_admin, 'at', now())) end
   where id = (p ->> 'id')::uuid returning * into a;
  if a.id is null then raise exception 'Application not found' using errcode = 'P0002'; end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_admin, 'application_check', 'owner_applications', a.id::text, jsonb_build_object('check', p ->> 'check', 'status', p ->> 'status'));
  return to_jsonb(a);
end $$;

create or replace function app.application_note(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  n owner_application_notes;
begin
  perform app.assert_admin(p_admin);
  insert into owner_application_notes (application_id, body, kind, created_by) values ((p ->> 'id')::uuid, btrim(p ->> 'body'), 'note', p_admin) returning * into n;
  return to_jsonb(n);
end $$;

-- Ask for something: the owner gets an email and a task in the owner portal; the application waits on the owner.
create or replace function app.application_request(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a owner_applications;
  v_items text[];
begin
  perform app.assert_admin(p_admin);
  select array_agg(x) into v_items from jsonb_array_elements_text(coalesce(p -> 'items', '[]'::jsonb)) x
   where x in (select e ->> 'code' from jsonb_array_elements(app.application_request_items()) e);
  if coalesce(cardinality(v_items), 0) = 0 then raise exception 'Choose what to ask for' using errcode = '22023'; end if;
  if 'other' = any (v_items) and nullif(btrim(coalesce(p ->> 'message', '')), '') is null then
    raise exception 'Say what else you need in the message' using errcode = '22023';
  end if;
  select * into a from owner_applications where id = (p ->> 'id')::uuid for update;
  if a.id is null then raise exception 'Application not found' using errcode = 'P0002'; end if;
  if a.status in ('approved', 'declined') then raise exception 'This application is % already', a.status using errcode = '23514'; end if;
  update owner_applications set status = 'waiting_on_owner', requested_items = v_items, request_message = nullif(btrim(p ->> 'message'), ''),
         requested_at = now(), owner_reply = null, owner_replied_at = null
   where id = a.id returning * into a;
  insert into owner_application_notes (application_id, body, kind, created_by)
  values (a.id, concat_ws(' ', 'Asked for: ' || (select string_agg(e ->> 'label', '; ') from jsonb_array_elements(app.application_request_items()) e where e ->> 'code' = any (v_items)) || '.',
                          a.request_message), 'request', p_admin);
  perform app.ntf_emit('owner_application_info_requested', 'owner_application', a.id, 'requested:' || to_char(a.requested_at, 'YYYYMMDDHH24MISS'),
                       jsonb_build_object('owner_id', a.owner_id));
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_admin, 'application_request', 'owner_applications', a.id::text, jsonb_build_object('items', v_items));
  return to_jsonb(a);
end $$;

-- The owner answers in the owner portal: the application is back in the inbox as new, with the reply.
create or replace function app.application_owner_reply(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a owner_applications;
begin
  select x.* into a from owner_applications x join owners o on o.id = x.owner_id
   where x.id = (p ->> 'id')::uuid and (o.user_id = p_by or app.user_is_owner_of(p_by, o.id)) for update of x;
  if a.id is null then raise exception 'Not found' using errcode = 'P0002'; end if;
  if a.status <> 'waiting_on_owner' then raise exception 'Nothing is waiting for your answer' using errcode = '23514'; end if;
  if nullif(btrim(coalesce(p ->> 'reply', '')), '') is null then raise exception 'Write your answer, or say where you uploaded the documents' using errcode = '22023'; end if;
  update owner_applications set status = 'new', owner_reply = btrim(p ->> 'reply'), owner_replied_at = now() where id = a.id returning * into a;
  insert into owner_application_notes (application_id, body, kind, created_by) values (a.id, a.owner_reply, 'reply', p_by);
  perform app.raise_task(p_type => 'owner_application_reply', p_queue => 'admin', p_title => format('Owner replied on application %s', a.application_number),
      p_detail => left(a.owner_reply, 400), p_owner => a.owner_id, p_related_table => 'owner_applications', p_related_id => a.id,
      p_dedupe => 'owner_application_reply:' || a.id || ':' || to_char(a.owner_replied_at, 'YYYYMMDDHH24MISS'));
  return jsonb_build_object('id', a.id, 'status', a.status);
end $$;

create or replace function app.application_decline(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a owner_applications;
begin
  perform app.assert_admin(p_admin);
  if nullif(btrim(coalesce(p ->> 'reason', '')), '') is null then raise exception 'Give the reason the owner reads' using errcode = '22023'; end if;
  select * into a from owner_applications where id = (p ->> 'id')::uuid for update;
  if a.id is null then raise exception 'Application not found' using errcode = 'P0002'; end if;
  if a.status in ('approved', 'declined') then raise exception 'This application is % already', a.status using errcode = '23514'; end if;
  update owner_applications set status = 'declined', decline_reason = btrim(p ->> 'reason'), decided_at = now(), decided_by = p_admin where id = a.id returning * into a;
  insert into owner_application_notes (application_id, body, kind, created_by) values (a.id, 'Declined: ' || a.decline_reason, 'decision', p_admin);
  update vehicle_onboardings ob set status = 'declined', decline_reason = a.decline_reason
    from vehicles v where v.id = ob.vehicle_id and v.owner_id = a.owner_id and ob.status = 'intake';
  -- each car declined: 0023's owner_application_declined email goes per car, with the reason
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_admin, 'application_decline', 'owner_applications', a.id::text, jsonb_build_object('reason', a.decline_reason));
  return to_jsonb(a);
end $$;

-- Approve: the owner becomes active; each car at intake gets its terms from the standard grid (0029's path, with the
-- government forms pre-filled), so the documents open for one signature in the owner portal; the first and last
-- month's invoices are issued by the existing rules (0029); the owner is emailed. Returns what was done.
create or replace function app.application_approve(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a owner_applications;
  r record;
  v_terms jsonb := '[]'::jsonb;
  v_invoices jsonb := '[]'::jsonb;
begin
  perform app.assert_admin(p_admin);
  select * into a from owner_applications where id = (p ->> 'id')::uuid for update;
  if a.id is null then raise exception 'Application not found' using errcode = 'P0002'; end if;
  if a.status = 'approved' then return jsonb_build_object('id', a.id, 'repeat', true); end if;
  if a.status = 'declined' then raise exception 'This application was declined' using errcode = '23514'; end if;
  update owners set status = 'active' where id = a.owner_id and status = 'lead';
  for r in select v.id from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id
            where v.owner_id = a.owner_id and ob.status = 'intake' order by v.created_at loop
    v_terms := v_terms || jsonb_build_array(app.admin_set_vehicle_terms(r.id, p_admin, coalesce(p -> 'terms', '{}'::jsonb)) - 'schedule');
  end loop;
  v_invoices := coalesce(app.admin_issue_upfront_invoices(a.owner_id, p_admin, null), '[]'::jsonb);
  update owner_applications set status = 'approved', decided_at = now(), decided_by = p_admin where id = a.id returning * into a;
  insert into owner_application_notes (application_id, body, kind, created_by)
  values (a.id, format('Approved: terms set for %s car(s), %s first and last month''s invoice(s) issued.', jsonb_array_length(v_terms), jsonb_array_length(v_invoices)), 'decision', p_admin);
  if not coalesce((p ->> 'no_email')::boolean, false) then
    perform app.ntf_emit('owner_application_approved', 'owner_application', a.id, 'approved', jsonb_build_object('owner_id', a.owner_id));
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_admin, 'application_approve', 'owner_applications', a.id::text, jsonb_build_object('terms', jsonb_array_length(v_terms), 'invoices', jsonb_array_length(v_invoices)));
  return jsonb_build_object('id', a.id, 'status', a.status, 'terms', v_terms, 'invoices', v_invoices);
end $$;

-- A new application lands in the inbox as new; staff are told as before (0022). The owner portal's task: what staff
-- asked for, until the owner answers.
create or replace function app.owner_application_task(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select (select jsonb_build_object('id', a.id, 'application_number', a.application_number, 'requested_at', a.requested_at, 'message', a.request_message,
            'items', (select coalesce(jsonb_agg(e ->> 'label'), '[]'::jsonb) from jsonb_array_elements(app.application_request_items()) e where e ->> 'code' = any (a.requested_items)))
            from owner_applications a join owners o on o.id = a.owner_id
           where (o.user_id = p_by) and a.status = 'waiting_on_owner' order by a.requested_at desc limit 1)
$$;

-- ================================================================ 3. To do, search
create or replace function app.admin_todo(p_admin uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_today date := app.today();
  ps program_settings := app.settings();
begin
  perform app.assert_admin(p_admin);
  return jsonb_build_object(
    'items', jsonb_build_array(
      jsonb_build_object('key', 'applications', 'label', 'Owner applications to review', 'button', 'Review applications', 'href', '/admin/applications',
                         'count', (select count(*) from owner_applications where status = 'new')),
      jsonb_build_object('key', 'requests', 'label', 'Booking requests waiting for an offer', 'button', 'Answer requests', 'href', '/admin/requests',
                         'count', (select count(*) from bookings where status = 'requested' and awaiting_renter_since is null)),
      jsonb_build_object('key', 'changes', 'label', 'Changes renters asked for, waiting for your answer', 'button', 'Answer changes', 'href', '/admin/requests?state=changes',
                         'count', (select count(*) from booking_change_requests where status = 'requested' and requested_by_role = 'renter')),
      jsonb_build_object('key', 'payments', 'label', 'Payments that failed or need recording', 'button', 'See payments', 'href', '/admin/money?status=failed',
                         'count', (select count(*) from payments p where p.status = 'failed' and p.created_at > now() - interval '30 days'
                                     and not exists (select 1 from payments y where y.status = 'succeeded' and y.created_at > p.created_at
                                                       and ((p.booking_id is not null and y.booking_id = p.booking_id and y.purpose = p.purpose)
                                                            or (p.owner_invoice_id is not null and y.owner_invoice_id = p.owner_invoice_id))))
                                  + (select count(*) from owner_invoices i where i.status in ('failed', 'in_arrears') and not exists (select 1 from owners o where o.id = i.owner_id and o.is_test))),
      jsonb_build_object('key', 'countersign', 'label', 'Agreements waiting for your countersignature', 'button', 'Countersign', 'href', '/admin/investors',
                         'count', (select count(*) from investment_agreements x where x.status = 'signed' and x.company_signed_at is null)),
      jsonb_build_object('key', 'tolls', 'label', 'Tolls and tickets to review', 'button', 'Review tolls', 'href', '/admin/tolls',
                         'count', (select count(*) from toll_work_queue where bucket in ('needs_review', 'unmatched'))),
      jsonb_build_object('key', 'listings', 'label', 'Listings to review', 'button', 'Review listings', 'href', '/admin/listings',
                         'count', (select count(*) from listing_intakes where state = 'needs_review')),
      jsonb_build_object('key', 'plates', 'label', 'Cars with licence plates not checked on their photos', 'button', 'Check plates', 'href', '/admin/listings?plates=unchecked',
                         'count', (select count(distinct ph.vehicle_id) from vehicle_photos ph join vehicles v on v.id = ph.vehicle_id
                                    where ph.replaced_at is null and ph.status = 'approved' and ph.processed_path is not null and ph.plate_status = 'unchecked'
                                      and v.retired_at is null and v.status <> 'exited')),
      jsonb_build_object('key', 'insurance', 'label', 'Insurance expiring or missing', 'button', 'See insurance', 'href', '/admin/partners',
                         'count', (select count(*) from tasks t where t.task_type in ('partner_insurance', 'insurer_provisional') and t.status in ('open', 'in_progress', 'waiting'))
                                  + (select count(*) from vehicle_onboardings ob join vehicles v on v.id = ob.vehicle_id
                                      where v.management_mode = 'turo_only' and v.status <> 'exited' and ob.owner_insurance_expires_on is not null
                                        and ob.owner_insurance_expires_on <= v_today + 30)),
      jsonb_build_object('key', 'samples', 'label', 'Cars using sample photos', 'button', 'Add real photos', 'href', '/admin/settings/sample-photos',
                         'count', (select count(*) from app.vehicles_using_sample_photos() u where u.listing_status in ('published', 'paused')))),
    'pickups', coalesce((select jsonb_agg(jsonb_build_object('booking_number', b.booking_number, 'at', b.pickup_at, 'vehicle', app.vehicle_name(b.vehicle_id),
                          'renter', r.legal_name, 'ready', coalesce((app.booking_readiness(b.id) ->> 'ready_for_handover')::boolean, false)) order by b.pickup_at)
                         from bookings b join renters r on r.id = b.renter_id
                        where b.status in ('confirmed', 'on_rent') and app.local_date(b.pickup_at) = v_today), '[]'::jsonb),
    'returns', coalesce((select jsonb_agg(jsonb_build_object('booking_number', b.booking_number, 'at', b.return_at, 'vehicle', app.vehicle_name(b.vehicle_id),
                          'renter', r.legal_name, 'late', b.return_at < now()) order by b.return_at)
                         from bookings b join renters r on r.id = b.renter_id
                        where b.status in ('confirmed', 'on_rent') and app.local_date(b.return_at) = v_today), '[]'::jsonb),
    'late', (select count(*) from bookings b where b.status = 'on_rent' and b.return_at < now()));
end $$;

-- One search box: booking number, plate, VIN, owner, partner, renter name or email; results grouped.
create or replace function app.admin_search(p_admin uuid, p_q text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  q text := btrim(coalesce(p_q, ''));
  l text;
  n text;
begin
  perform app.assert_admin(p_admin);
  if length(q) < 2 then return jsonb_build_object('q', q, 'groups', '[]'::jsonb); end if;
  l := '%' || replace(replace(replace(lower(q), '\', '\\'), '%', '\%'), '_', '\_') || '%';
  n := upper(regexp_replace(q, '[^A-Za-z0-9]', '', 'g'));
  return jsonb_build_object('q', q, 'groups', jsonb_build_array(
    jsonb_build_object('key', 'bookings', 'label', 'Bookings', 'rows', coalesce((select jsonb_agg(x) from (
        select jsonb_build_object('title', b.booking_number, 'sub', concat_ws(' · ', r.legal_name, app.vehicle_name(b.vehicle_id), replace(b.status::text, '_', ' ')),
                                  'href', '/admin/bookings/' || b.booking_number) x
          from bookings b left join renters r on r.id = b.renter_id
         where upper(b.booking_number) like '%' || n || '%' or lower(coalesce(b.agreement_number, '')) like l
         order by b.pickup_at desc limit 8) s), '[]'::jsonb)),
    jsonb_build_object('key', 'cars', 'label', 'Cars', 'rows', coalesce((select jsonb_agg(x) from (
        select jsonb_build_object('title', app.vehicle_name(v.id), 'sub', concat_ws(' · ', 'plate ' || nullif(v.plate, ''), 'VIN ' || v.vin, replace(v.status::text, '_', ' ')),
                                  'href', '/admin/vehicles/' || v.id) x
          from vehicles v
         where (n <> '' and (upper(coalesce(v.plate, '')) like '%' || n || '%' or upper(coalesce(v.vin, '')) like '%' || n || '%'))
            or lower(concat_ws(' ', v.year::text, v.make, v.model)) like l or lower(coalesce(v.fleet_number, '')) like l
         order by v.created_at desc limit 8) s), '[]'::jsonb)),
    jsonb_build_object('key', 'owners', 'label', 'Owners', 'rows', coalesce((select jsonb_agg(x) from (
        select jsonb_build_object('title', o.legal_name, 'sub', concat_ws(' · ', o.email, o.phone, o.status), 'href', '/admin/owners/' || o.id) x
          from owners o
         where o.kind = 'program' and (lower(o.legal_name) like l or lower(coalesce(o.email, '')) like l or lower(coalesce(o.corporation_name, '')) like l
                                       or regexp_replace(coalesce(o.phone, ''), '\D', '', 'g') like '%' || nullif(regexp_replace(q, '\D', '', 'g'), '') || '%')
         order by o.created_at desc limit 8) s), '[]'::jsonb)),
    jsonb_build_object('key', 'partners', 'label', 'Partners', 'rows', coalesce((select jsonb_agg(x) from (
        select jsonb_build_object('title', coalesce(p.business_name, p.legal_name), 'sub', concat_ws(' · ', p.email, p.phone), 'href', '/admin/partners/' || p.id) x
          from partners p
         where lower(coalesce(p.business_name, '')) like l or lower(coalesce(p.legal_name, '')) like l or lower(coalesce(p.email, '')) like l
         order by p.created_at desc limit 8) s), '[]'::jsonb)),
    jsonb_build_object('key', 'renters', 'label', 'Renters', 'rows', coalesce((select jsonb_agg(x) from (
        select jsonb_build_object('title', r.legal_name, 'sub', concat_ws(' · ', r.email, r.mobile), 'href', '/admin/renters?q=' || coalesce(r.email, r.legal_name)) x
          from renters r
         where lower(coalesce(r.legal_name, '')) like l or lower(coalesce(r.email, '')) like l
            or regexp_replace(coalesce(r.mobile, ''), '\D', '', 'g') like '%' || nullif(regexp_replace(q, '\D', '', 'g'), '') || '%'
         order by r.created_at desc limit 8) s), '[]'::jsonb))));
end $$;

-- ================================================================ 5. the emails' values
alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_0053;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_0053(p_code, p_event, p_to);
  a owner_applications;
  o owners;
begin
  if p_code in ('owner_application_info_requested', 'owner_application_approved') then
    select * into a from owner_applications where id = p_event.entity_id;
    select * into o from owners where id = a.owner_id;
    x := x || jsonb_build_object(
      'first_name', coalesce(nullif(x ->> 'first_name', ''), o.first_name, split_part(o.legal_name, ' ', 1)),
      'application_number', a.application_number,
      'vehicle_name', (select string_agg(app.vehicle_name(v.id), ', ' order by v.created_at) from vehicles v where v.owner_id = o.id),
      'requested_items', (select coalesce(jsonb_agg(jsonb_build_object('item', e ->> 'label')), '[]'::jsonb) from jsonb_array_elements(app.application_request_items()) e where e ->> 'code' = any (a.requested_items)),
      'request_message', coalesce(a.request_message, ''), 'has_message', a.request_message is not null,
      'decline_reason', coalesce(a.decline_reason, ''),
      'invoice_count', (select count(*) from owner_invoices i where i.owner_id = o.id and i.kind = 'upfront' and i.status = 'issued'));
  end if;
  return x;
end $$;

-- ================================================================ 6. the doors
create or replace function app.ops54(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  case p_name
  when 'admin_access' then return app.admin_access_read(p_user);
  when 'admin_access_save' then return app.admin_access_save(p_user, p);
  when 'sample_photos' then return app.sample_photos_read(p_user);
  when 'sample_photo_save' then return app.sample_photo_save(p_user, p);
  when 'sample_photo_delete' then return app.sample_photo_delete(p_user, p);
  when 'vehicles_using_samples' then
    perform app.assert_admin(p_user);
    return (select coalesce(jsonb_agg(jsonb_build_object('vehicle_id', u.vehicle_id, 'listing_status', u.listing_status, 'body_key', u.body_key)), '[]'::jsonb) from app.vehicles_using_sample_photos() u);
  when 'admin_todo' then return app.admin_todo(p_user);
  when 'admin_search' then return app.admin_search(p_user, p ->> 'q');
  when 'applications' then return app.applications_list(p_user, p);
  when 'application' then return app.application_view(p_user, (p ->> 'id')::uuid);
  when 'application_check' then return app.application_check(p_user, p);
  when 'application_note' then return app.application_note(p_user, p);
  when 'application_request' then return app.application_request(p_user, p);
  when 'application_decline' then return app.application_decline(p_user, p);
  when 'application_approve' then return app.application_approve(p_user, p);
  else raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_0053;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_reads constant text[] := array['admin_access', 'sample_photos', 'vehicles_using_samples', 'admin_todo', 'admin_search', 'applications', 'application'];
  v_does constant text[] := array['admin_access_save', 'sample_photo_save', 'sample_photo_delete', 'application_check', 'application_note', 'application_request',
                                  'application_decline', 'application_approve'];
begin
  if (p_call = 'ops_read' and p_name = any (v_reads)) or (p_call = 'ops_do' and p_name = any (v_does)) then
    perform app.door_begin(p_user, p_aal);
    return app.ops54(p_user, p_call, p_name, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_0053(p_user, p_aal, p_call, p_name, p);
end $$;

-- The server's own calls (as the service role): the owner portal's application task and the owner's reply.
create or replace function public.server_owner_application_task(p_by uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_application_task(p_by) $$;
create or replace function public.server_application_owner_reply(p_by uuid, p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.application_owner_reply(p_by, p) $$;

-- ================================================================ 7. privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array[
              'admin_email_allowed', 'user_roles_admin_guard', 'users_admin_email_guard', 'admin_access_read', 'admin_access_save',
              'sample_body_key', 'vehicle_uses_sample_photos', 'vehicle_sample_photos', 'submit_listing_intake', 'listing_photo_problems', 'publish_listing',
              'public_listing_photos', 'public_listing_row', 'vehicles_using_sample_photos', 'sample_photos_read', 'sample_photo_save', 'sample_photo_delete',
              'application_view', 'applications_list', 'application_check', 'application_note', 'application_request', 'application_owner_reply',
              'application_decline', 'application_approve', 'owner_application_task', 'admin_todo', 'admin_search', 'ops54', 'door']))
        or (n.nspname = 'public' and p.proname = any (array['server_owner_application_task', 'server_application_owner_reply']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- Each renamed function keeps its privileges; the function in its place gets the same.
do $$
declare
  r record;
  v_new regprocedure;
  g text;
begin
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('ntf_payload_0053', 'notification_payload'), ('door_0053', 'door'), ('submit_listing_intake_0022', 'submit_listing_intake'), ('publish_listing_0042', 'publish_listing'),
                          ('listing_photo_problems_0022', 'listing_photo_problems'), ('public_listing_photos_0022', 'public_listing_photos'),
                          ('public_listing_row_0022', 'public_listing_row')) m(old_name, new_name)
               on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    execute format('revoke all on function %s from public, anon, authenticated', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;

-- ================================================================ 8. the email catalogue
-- CATALOGUE 0054 START (generated by supabase/seed/0054_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('owner_application_info_requested', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'We need a little more for application {{application_number}}', 'A few items for your {{vehicle_name}}, then we can send your terms.', 'Immediate', 'An Admin presses "Ask for something" on an owner application (Admin > Owners and partners > Applications) and chooses what is needed. The owner also sees it as a task in the owner portal until they answer. One email per request.', null, '/owner', '[{"name":"application_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"has_message","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"request_message","type":"string"},{"name":"requested_items","type":"list","fields":["item"]},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_application_info_requested.html', 'templates/owner_application_info_requested.txt'),
  ('owner_application_approved', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Approved: your {{vehicle_name}} can join CarmaCars', 'Sign your documents and pay the first invoice in your owner portal.', 'Immediate', 'An Admin approves an owner application (Admin > Owners and partners > Applications > Approve): the owner is active, each car has its terms from the standard grid, the agreements open for one signature in the owner portal, and the first and last month''s invoices are issued by the existing rules (their own emails go too).', null, '/owner', '[{"name":"application_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"invoice_count","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_application_approved.html', 'templates/owner_application_approved.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0054 END
update notification_catalogue set emitted_by = 'app.application_request (0054)' where code = 'owner_application_info_requested';
update notification_catalogue set emitted_by = 'app.application_approve (0054)' where code = 'owner_application_approved';
select app.attach_audit();
