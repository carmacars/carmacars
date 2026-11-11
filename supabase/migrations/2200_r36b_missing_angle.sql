-- 2200_r36b_missing_angle.sql
-- Release 36b, item 1. The owner: "if a photo has not been taken in a specific angle then it should be able to generate a
-- photo of the car in the angle."
--   1. listing_angle_makes: an AI view of a required angle the car has no photo of, made from the car's other approved photos
--      by the image model (the listing worker, job kind angle_make) behind the same gate and daily free limit as the
--      showroom and the "with a model" covers (app.showroom_ai_gate, 0990: Program settings listing_showroom_ai and
--      listing_showroom_ai_daily; a quota answer stops it for the hour). Never past the free use.
--   2. Marked as generated (the table is generated views only; generated is always true), shown to staff for approval:
--      Admin, Fleet or Sales press Make, then Approve or Reject. Only an approved one is shown, and only after the car's real
--      photos and only while the car still has no real photo of that angle.
--   3. Never the cover and never evidence: a generated view is not a vehicle_photos row, so the cover (app.cover_photo),
--      the made covers, the handover photo set, condition reports and claims (which read vehicle_photos and the
--      condition photos) never see it. The site's gallery labels it "AI view".
-- No applied migration is edited: worker_listing_result, public_listing_photos and the door are wrapped.
set local check_function_bodies = off;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. the setting and the table
alter table program_settings
  add column if not exists listing_angle_prompt text not null default
    'The images are photos of one real car, {car}. Make one realistic photo of this exact car seen from the {angle} view, as a professional dealership photographer would take it: the same make, model, trim, colour, wheels, badges, lights and condition, nothing added, removed or improved, no damage hidden or invented, no people, no text, no licence plate number (leave the plate blank). The same background and light as the photos.'
    check (length(listing_angle_prompt) between 40 and 2000 and listing_angle_prompt like '%{angle}%');
comment on column program_settings.listing_angle_prompt is 'Missing angle (2200): the image model''s words for a view of the car that was never photographed. {angle} is the view (Front, Rear left...), {car} the year, make and model. Staff approve every result before it is shown.';

create table if not exists listing_angle_makes (
  id          uuid primary key default gen_random_uuid(),
  vehicle_id  uuid not null references vehicles (id) on delete cascade,
  shot_type   text not null references listing_shot_types (code),
  generated   boolean not null default true check (generated),
  sources     uuid[] not null check (cardinality(sources) between 1 and 3),
  status      text not null default 'queued' check (status in ('queued', 'made', 'needs_gemini', 'failed', 'approved', 'rejected')),
  path        text check (path is null or path ~ '^vehicles/[0-9a-f-]{36}/generated/[0-9a-f-]{36}\.(jpg|png)$'),
  width       integer,
  height      integer,
  provider    text,
  note        text check (note is null or length(note) <= 300),
  job_id      uuid references listing_jobs (id) on delete set null,
  created_by  uuid references users (id),
  reviewed_by uuid references users (id),
  reviewed_at timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (status not in ('made', 'approved') or path is not null),
  check (status <> 'approved' or reviewed_by is not null)
);
comment on table listing_angle_makes is 'Missing angle (2200): AI-generated views of an angle the car was never photographed at. Always generated; shown on the site only once staff approve it, after the real photos, never as the cover and never as damage or condition evidence (handover reports and claims read vehicle_photos only).';
create index if not exists listing_angle_makes_vehicle on listing_angle_makes (vehicle_id, shot_type, created_at desc);
-- one at a time per angle: a view being made, waiting for approval or approved
create unique index if not exists listing_angle_makes_open on listing_angle_makes (vehicle_id, shot_type) where status in ('queued', 'made', 'approved');
create trigger listing_angle_makes_updated before update on listing_angle_makes for each row execute function app.set_updated_at();
create trigger audit_listing_angle_makes after insert or update or delete on listing_angle_makes for each row execute function app.audit_row();
alter table listing_angle_makes enable row level security;
create policy admin_all on listing_angle_makes for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on listing_angle_makes from public, anon, authenticated;
grant select on listing_angle_makes to authenticated;
grant all on listing_angle_makes to service_role;

alter table listing_jobs drop constraint if exists listing_jobs_kind_check;
alter table listing_jobs add constraint listing_jobs_kind_check check (kind in ('decode_vin', 'draft_copy', 'process_photo', 'resize', 'publish', 'marketing_photo', 'plate_redo',
  'cover_model', 'cover_flyer', 'angle_make'));

-- ================================================================ 2. who, and what is missing
-- Admin, Fleet and Sales make and approve generated views (the listing page and the Marketplace kit)
create or replace function app.angle_may(p_by uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_is_admin(p_by) or app.user_va_has(p_by, 'fleet', 'sales')
$$;

-- the car's real photos of an angle (any photo not rejected or replaced counts as taken)
create or replace function app.angle_taken(p_vehicle uuid, p_shot text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from vehicle_photos ph where ph.vehicle_id = p_vehicle and ph.shot_type = p_shot and ph.replaced_at is null and ph.status <> 'rejected')
$$;

-- the photos a view is made from: up to three approved, processed, public photos, outside views first for an outside angle
create or replace function app.angle_sources(p_vehicle uuid, p_shot text) returns uuid[]
language sql stable security definer set search_path = public, app as $$
  select coalesce(array_agg(id), '{}') from (
    select ph.id from vehicle_photos ph join listing_shot_types st on st.code = ph.shot_type
      join listing_shot_types want on want.code = p_shot
     where ph.vehicle_id = p_vehicle and ph.replaced_at is null and ph.status = 'approved' and ph.is_public and st.is_public and ph.processed_path is not null
     order by (st.rebackground = want.rebackground) desc, ph.is_cover desc, st.seq, ph.created_at limit 3) x
$$;

create or replace function app.listing_angles_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid; ps program_settings := app.settings();
begin
  if not app.angle_may(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  if v_vehicle is null or not exists (select 1 from vehicles where id = v_vehicle) then raise exception 'Unknown car' using errcode = 'P0002'; end if;
  return jsonb_build_object('vehicle', v_vehicle, 'ai_on', coalesce(ps.listing_showroom_ai, false),
    'sources', cardinality(app.angle_sources(v_vehicle, 'front_left')),
    'missing', coalesce((select jsonb_agg(jsonb_build_object('shot', st.code, 'label', st.label) order by st.seq) from listing_shot_types st
                          where st.is_active and st.required and st.is_public and not app.angle_taken(v_vehicle, st.code)), '[]'::jsonb),
    'made', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'shot', m.shot_type, 'label', st.label, 'status', m.status, 'path', m.path, 'note', m.note,
                       'generated', m.generated, 'taken', app.angle_taken(v_vehicle, m.shot_type), 'at', m.updated_at) order by st.seq, m.created_at desc)
                        from listing_angle_makes m join listing_shot_types st on st.code = m.shot_type
                       where m.vehicle_id = v_vehicle and (m.status in ('queued', 'made', 'approved', 'needs_gemini', 'failed') and m.created_at > now() - interval '30 days' or m.status = 'approved')), '[]'::jsonb));
end $$;

-- ================================================================ 3. making one
-- p: vehicle, shot
create or replace function app.listing_angle_make(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid;
  v_shot text := nullif(p ->> 'shot', '');
  st listing_shot_types;
  v vehicles;
  ps program_settings := app.settings();
  v_src uuid[];
  v_intake uuid;
  v_id uuid;
  v_job uuid;
begin
  if not app.angle_may(p_by) then raise exception 'An Admin, Fleet or Sales makes a missing angle' using errcode = '42501'; end if;
  select * into v from vehicles where id = v_vehicle;
  if v.id is null then raise exception 'Unknown car' using errcode = 'P0002'; end if;
  select * into st from listing_shot_types where code = v_shot and is_active;
  if st.code is null or not st.required or not st.is_public then raise exception 'Only a required angle shown on the site can be made' using errcode = '22023'; end if;
  if app.angle_taken(v_vehicle, v_shot) then raise exception 'This car already has a % photo: a real photo always wins', st.label using errcode = '23514'; end if;
  if not coalesce(ps.listing_showroom_ai, false) then raise exception 'The image model is off in Program settings (Listings > Showroom image model)' using errcode = '23514'; end if;
  if exists (select 1 from listing_angle_makes where vehicle_id = v_vehicle and shot_type = v_shot and status in ('queued', 'made', 'approved')) then
    raise exception 'A % view is already being made, waiting for approval or approved: reject it first to make another', st.label using errcode = '23505';
  end if;
  v_src := app.angle_sources(v_vehicle, v_shot);
  if cardinality(v_src) = 0 then raise exception 'The car needs at least one approved photo on the site to make a view from' using errcode = '23514'; end if;
  v_intake := (select i.id from listing_intakes i where i.vehicle_id = v_vehicle order by i.created_at desc limit 1);
  if v_intake is null then raise exception 'The car has no listing yet' using errcode = '23514'; end if;
  insert into listing_angle_makes (vehicle_id, shot_type, sources, created_by) values (v_vehicle, v_shot, v_src, p_by) returning id into v_id;
  v_job := app.enqueue_listing_job(v_intake, 'angle_make', v_src[1], jsonb_build_object('angle', jsonb_build_object(
    'id', v_id, 'vehicle_id', v_vehicle, 'shot', v_shot, 'label', st.label,
    'sources', (select jsonb_agg(ph.processed_path order by array_position(v_src, ph.id)) from vehicle_photos ph where ph.id = any (v_src)),
    'prompt', replace(replace(ps.listing_angle_prompt, '{angle}', lower(st.label)), '{car}', btrim(concat_ws(' ', v.year::text, v.make, v.model))))));
  update listing_angle_makes set job_id = v_job where id = v_id;
  return app.listing_angles_read(p_by, jsonb_build_object('vehicle', v_vehicle));
end $$;

-- p: id, action (approve | reject)
create or replace function app.listing_angle_decide(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare m listing_angle_makes; v_action text := p ->> 'action';
begin
  if not app.angle_may(p_by) then raise exception 'An Admin, Fleet or Sales approves a generated view' using errcode = '42501'; end if;
  select * into m from listing_angle_makes where id = nullif(p ->> 'id', '')::uuid for update;
  if m.id is null then raise exception 'Unknown view' using errcode = 'P0002'; end if;
  if v_action = 'approve' then
    if m.status <> 'made' then raise exception 'Only a made view waiting for approval can be approved' using errcode = '23514'; end if;
    if app.angle_taken(m.vehicle_id, m.shot_type) then raise exception 'The car has a real photo of this angle now: the real photo is used' using errcode = '23514'; end if;
    update listing_angle_makes set status = 'approved', reviewed_by = p_by, reviewed_at = now() where id = m.id;
  elsif v_action = 'reject' then
    if m.status not in ('made', 'approved', 'needs_gemini', 'failed', 'queued') then raise exception 'Already rejected' using errcode = '23514'; end if;
    update listing_angle_makes set status = 'rejected', reviewed_by = p_by, reviewed_at = now() where id = m.id;
  else raise exception 'Approve or reject' using errcode = '22023';
  end if;
  return app.listing_angles_read(p_by, jsonb_build_object('vehicle', m.vehicle_id));
end $$;

-- the worker's answer: the view made (or why not)
alter function app.worker_listing_result(uuid, jsonb) rename to worker_listing_result_pre2200;
create function app.worker_listing_result(p_job uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare j listing_jobs; r jsonb; c jsonb := p #> '{output,angle}';
begin
  select * into j from listing_jobs where id = p_job;
  r := app.worker_listing_result_pre2200(p_job, p);
  if j.kind = 'angle_make' then
    update listing_angle_makes x
       set status = case when not coalesce((p ->> 'ok')::boolean, false) then case when coalesce((p ->> 'retryable')::boolean, true) and (select status from listing_jobs where id = p_job) <> 'failed' then 'queued' else 'failed' end
                         when c ->> 'status' = 'made' and (c ->> 'path') ~ ('^vehicles/' || x.vehicle_id || '/generated/') then 'made'
                         when c ->> 'status' in ('needs_gemini', 'failed') then c ->> 'status' else 'failed' end,
           path = case when c ->> 'status' = 'made' and (c ->> 'path') ~ ('^vehicles/' || x.vehicle_id || '/generated/') then c ->> 'path' end,
           width = nullif(c ->> 'width', '')::integer, height = nullif(c ->> 'height', '')::integer,
           provider = left(c ->> 'provider', 40), note = left(coalesce(c ->> 'note', case when not coalesce((p ->> 'ok')::boolean, false) then p ->> 'error' end), 300)
     where x.id = coalesce(nullif(c ->> 'id', '')::uuid, nullif(j.input #>> '{angle,id}', '')::uuid) and x.status = 'queued';
  end if;
  return r;
end $$;
select pg_temp.copy_grants('app.worker_listing_result(uuid, jsonb)'::regprocedure, 'app.worker_listing_result_pre2200(uuid, jsonb)'::regprocedure);

-- ================================================================ 4. the site: approved views after the real photos, labelled
alter function app.public_listing_photos(uuid) rename to public_listing_photos_pre2200;
create function app.public_listing_photos(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(app.public_listing_photos_pre2200(p_vehicle), '[]'::jsonb)
      || coalesce((select jsonb_agg(jsonb_build_object('path', m.path, 'variants', '[]'::jsonb, 'width', m.width, 'height', m.height, 'shot', m.shot_type,
                     'label', st.label || ' (AI view)', 'is_cover', false, 'generated', true,
                     'alt', app.vehicle_name(p_vehicle) || ', ' || lower(st.label) || ' view (AI-generated)') order by st.seq)
                    from listing_angle_makes m join listing_shot_types st on st.code = m.shot_type
                   where m.vehicle_id = p_vehicle and m.status = 'approved' and m.path is not null and not app.angle_taken(p_vehicle, m.shot_type)), '[]'::jsonb)
$$;
select pg_temp.copy_grants('app.public_listing_photos(uuid)'::regprocedure, 'app.public_listing_photos_pre2200(uuid)'::regprocedure);

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2200;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call in ('ops_read', 'va_read') and p_name = 'listing_angles') or (p_call in ('ops_do', 'va_do') and p_name in ('listing_angle_make', 'listing_angle_decide')) then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    p := coalesce(p, '{}'::jsonb) - '_va';
    return case p_name when 'listing_angles' then app.listing_angles_read(p_user, p) when 'listing_angle_make' then app.listing_angle_make(p_user, p)
                       else app.listing_angle_decide(p_user, p) end;
  end if;
  return app.door_pre2200(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2200(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['angle_may', 'angle_taken', 'angle_sources', 'listing_angles_read', 'listing_angle_make', 'listing_angle_decide',
              'door_pre2200', 'worker_listing_result_pre2200', 'public_listing_photos_pre2200'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
