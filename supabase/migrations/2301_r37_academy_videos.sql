-- 2301_r37_academy_videos.sql (release 37)
-- The academy's animated lessons as real video files (MP4 where the browser records it, WebM otherwise), made free in the
-- browser the way the short car videos are (2210): the scenes drawn on a canvas and recorded with MediaRecorder, then kept
-- in the private documents bucket under academy/videos/<lesson>/<id>.<ext>.
--   1. academy_lesson_videos: one row per saved file, with the lesson's scenes hash at the time; a video whose hash is not
--      the lesson's current one is stale (the lesson changed) and is not offered, so a video never teaches old words.
--   2. Who: anyone who may watch the lesson (an Admin, or staff whose path has the section open: 0207's rule) reads its
--      video and may save one by pressing "Watch as video" when none is current; an Admin renders the missing ones.
--   3. The door: ops_read academy_videos {lesson?} and ops_do academy_video_save {lesson, path, mime, seconds, bytes} and
--      academy_video_remove {id} (Admin only).

create table if not exists academy_lesson_videos (
  id          uuid primary key default gen_random_uuid(),
  lesson_id   uuid not null references academy_lessons (id) on delete cascade,
  scenes_hash text not null,
  path        text not null unique,
  mime        text not null check (mime in ('video/mp4', 'video/webm')),
  seconds     numeric(6,1) not null check (seconds > 0 and seconds <= 3600),
  bytes       bigint not null check (bytes > 0 and bytes <= 200 * 1024 * 1024),
  created_by  uuid references users (id),
  created_at  timestamptz not null default now(),
  removed_at  timestamptz
);
comment on table academy_lesson_videos is 'Academy lesson videos (2301): a lesson''s scenes recorded in the browser as MP4 or WebM, kept in the private documents bucket; stale when scenes_hash differs from the lesson''s current scenes.';
create index if not exists academy_lesson_videos_lesson on academy_lesson_videos (lesson_id, created_at desc) where removed_at is null;
drop trigger if exists audit_academy_lesson_videos on academy_lesson_videos;
create trigger audit_academy_lesson_videos after insert or update or delete on academy_lesson_videos for each row execute function app.audit_row();
alter table academy_lesson_videos enable row level security;
drop policy if exists admin_all on academy_lesson_videos;
create policy admin_all on academy_lesson_videos for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on academy_lesson_videos from public, anon, authenticated;
grant select, insert, update, delete on academy_lesson_videos to service_role;

create or replace function app.academy_scenes_hash(p_scenes jsonb) returns text language sql immutable as $$ select md5(coalesce(p_scenes, '[]'::jsonb)::text) $$;

-- may this person watch the lesson (0207 academy_viewed's rule)
create or replace function app.academy_may_watch(p_user uuid, p_lesson uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_is_admin(p_user) or exists (select 1 from academy_lessons l join academy_path_sections ps on ps.section_id = l.section_id
     where l.id = p_lesson and ps.path_code = any (app.academy_paths_of(p_user)) and app.academy_open(p_user, ps.path_code, ps.section_id))
$$;

-- p: lesson (one lesson: its current video or null) or nothing (an Admin: every lesson, with its current video or none)
create or replace function app.academy_videos(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_lesson uuid := nullif(p ->> 'lesson', '')::uuid;
begin
  if v_lesson is null and not app.user_is_admin(p_by) then raise exception 'An Admin renders the lesson videos' using errcode = '42501'; end if;
  if v_lesson is not null and not app.academy_may_watch(p_by, v_lesson) then raise exception 'Pass the section before this one first' using errcode = '42501'; end if;
  return jsonb_build_object('lessons', coalesce((select jsonb_agg(jsonb_build_object('lesson', l.id, 'title', l.title, 'scenes', l.scenes,
      'video', (select jsonb_build_object('id', v.id, 'mime', v.mime, 'seconds', v.seconds, 'bytes', v.bytes, 'at', v.created_at, 'path', v.path)
                  from academy_lesson_videos v where v.lesson_id = l.id and v.removed_at is null and v.scenes_hash = app.academy_scenes_hash(l.scenes)
                 order by v.created_at desc limit 1)) order by s.slug, l.sort)
    from academy_lessons l join academy_sections s on s.id = l.section_id
   where (v_lesson is null or l.id = v_lesson) and jsonb_array_length(l.scenes) > 0), '[]'::jsonb));
end $$;

-- p: lesson, path, mime, seconds, bytes (the file is already in the documents bucket under the lesson's folder)
create or replace function app.academy_video_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_lesson academy_lessons; v_id uuid;
begin
  select * into v_lesson from academy_lessons where id = nullif(p ->> 'lesson', '')::uuid;
  if v_lesson.id is null then raise exception 'No such lesson' using errcode = 'P0002'; end if;
  if not app.academy_may_watch(p_by, v_lesson.id) then raise exception 'Pass the section before this one first' using errcode = '42501'; end if;
  if coalesce(p ->> 'path', '') !~ ('^academy/videos/' || v_lesson.id || '/[0-9a-f-]{36}\.(mp4|webm)$') then raise exception 'The video is not in this lesson''s folder' using errcode = '22023'; end if;
  -- one current video a lesson: a second recording of the same scenes is not kept (the first one stays)
  if exists (select 1 from academy_lesson_videos where lesson_id = v_lesson.id and removed_at is null and scenes_hash = app.academy_scenes_hash(v_lesson.scenes)) then
    return app.academy_videos(p_by, jsonb_build_object('lesson', v_lesson.id)) || jsonb_build_object('saved', null, 'kept', 'existing');
  end if;
  update academy_lesson_videos set removed_at = now() where lesson_id = v_lesson.id and removed_at is null;
  insert into academy_lesson_videos (lesson_id, scenes_hash, path, mime, seconds, bytes, created_by)
  values (v_lesson.id, app.academy_scenes_hash(v_lesson.scenes), p ->> 'path', p ->> 'mime', (p ->> 'seconds')::numeric, (p ->> 'bytes')::bigint, p_by)
  returning id into v_id;
  return app.academy_videos(p_by, jsonb_build_object('lesson', v_lesson.id)) || jsonb_build_object('saved', v_id);
end $$;

-- p: id (an Admin removes a bad recording; the next "Watch as video" makes it again)
create or replace function app.academy_video_remove(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare x academy_lesson_videos;
begin
  if not app.user_is_admin(p_by) then raise exception 'An Admin removes lesson videos' using errcode = '42501'; end if;
  update academy_lesson_videos set removed_at = now() where id = nullif(p ->> 'id', '')::uuid and removed_at is null returning * into x;
  if x.id is null then raise exception 'Unknown video' using errcode = 'P0002'; end if;
  return app.academy_videos(p_by, jsonb_build_object('lesson', x.lesson_id)) || jsonb_build_object('removed_path', x.path);
end $$;

-- ================================================================ the door
create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2301;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call in ('ops_read', 'va_read') and p_name = 'academy_videos') or (p_call in ('ops_do', 'va_do') and p_name in ('academy_video_save', 'academy_video_remove')) then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    p := coalesce(p, '{}'::jsonb) - '_va';
    return case p_name when 'academy_videos' then app.academy_videos(p_user, p) when 'academy_video_save' then app.academy_video_save(p_user, p)
                       else app.academy_video_remove(p_user, p) end;
  end if;
  return app.door_pre2301(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2301(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['academy_videos', 'academy_video_save', 'academy_video_remove', 'academy_may_watch', 'door_pre2301'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
