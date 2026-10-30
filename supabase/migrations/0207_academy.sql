-- 0207: the training academy (Release 21b, item 9). SCHEMA_MARKER 0207. docs/changes/2026-11-01-academy.md.
--   A path per staff function (customer service, fleet, finance, Sales in person, Sales remote, field work, Admin): sections
--   of lessons, and a quiz per section. A lesson is a video made in the browser: scenes (a caption, the words the browser's
--   voice says, and what the screen shows) played by the scene player of web/src/features/academy; no media is stored.
--   The quiz passes at academy_pass_bps (80% by default); a passed section opens the next one of the path; retries are
--   allowed. An Admin edits the paths' sections, lessons, scenes and questions, opens a section early for one person and
--   sees everyone's progress. A section can be on several paths (the policies every renter-facing role needs): passed once,
--   it counts on each.
--   Program settings: academy_gate (off by default). Off, the academy only records progress. On, a staff member who has not
--   passed every path of their functions opens only the academy, the guide and their profile in the staff portal.
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

-- ================================================================ 1. tables
create table academy_paths (
  code   text primary key check (code in ('cs', 'fleet', 'finance', 'sales_in_person', 'sales_remote', 'field', 'admin')),
  title  text not null check (length(btrim(title)) between 1 and 80),
  blurb  text not null default '' check (length(blurb) <= 400),
  sort   int not null default 0
);
comment on table academy_paths is 'The academy''s paths (0207), one per staff function (Sales in person and remote apart, and Admin).';

create table academy_sections (
  id     uuid primary key default gen_random_uuid(),
  slug   text not null unique check (slug ~ '^[a-z0-9-]{2,60}$'),
  title  text not null check (length(btrim(title)) between 1 and 100),
  blurb  text not null default '' check (length(blurb) <= 400),
  updated_at timestamptz not null default now(),
  updated_by uuid references users (id)
);
comment on table academy_sections is 'A section of lessons with its quiz (0207). It can be on several paths (academy_path_sections).';

create table academy_path_sections (
  path_code  text not null references academy_paths (code) on delete cascade,
  section_id uuid not null references academy_sections (id) on delete cascade,
  sort       int not null,
  primary key (path_code, section_id),
  unique (path_code, sort)
);
comment on table academy_path_sections is 'The sections of each path, in order (0207): a section opens once the one before it on the path is passed.';

create table academy_lessons (
  id         uuid primary key default gen_random_uuid(),
  section_id uuid not null references academy_sections (id) on delete cascade,
  sort       int not null,
  title      text not null check (length(btrim(title)) between 1 and 100),
  scenes     jsonb not null default '[]'::jsonb check (jsonb_typeof(scenes) = 'array'),
  updated_at timestamptz not null default now(),
  updated_by uuid references users (id),
  unique (section_id, sort)
);
comment on table academy_lessons is 'A lesson (0207): its scenes, each {caption, say, visual: {kind, ...}}, played and narrated in the browser.';
comment on column academy_lessons.scenes is 'Scenes in order: caption (on screen), say (the narration; the caption when empty) and visual (kind: title, chat, list, steps, money, rule; with heading, text, items, lines, rows).';

create table academy_questions (
  id         uuid primary key default gen_random_uuid(),
  section_id uuid not null references academy_sections (id) on delete cascade,
  sort       int not null,
  prompt     text not null check (length(btrim(prompt)) between 1 and 400),
  options    jsonb not null check (jsonb_typeof(options) = 'array' and jsonb_array_length(options) between 2 and 6),
  answer     int not null check (answer >= 0),
  explain    text not null default '' check (length(explain) <= 600),
  updated_at timestamptz not null default now(),
  updated_by uuid references users (id),
  unique (section_id, sort),
  check (answer < jsonb_array_length(options))
);
comment on table academy_questions is 'A quiz question of a section (0207): the options and the index of the right one, with why.';

create table academy_lesson_views (
  user_id   uuid not null references users (id) on delete cascade,
  lesson_id uuid not null references academy_lessons (id) on delete cascade,
  viewed_at timestamptz not null default now(),
  primary key (user_id, lesson_id)
);
comment on table academy_lesson_views is 'A lesson watched to the end by a staff member (0207).';

create table academy_attempts (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references users (id) on delete cascade,
  section_id uuid not null references academy_sections (id) on delete cascade,
  correct    int not null check (correct >= 0),
  total      int not null check (total > 0 and correct <= total),
  score_bps  int not null check (score_bps between 0 and 10000),
  passed     boolean not null,
  answers    jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);
create index academy_attempts_user on academy_attempts (user_id, section_id, created_at desc);
comment on table academy_attempts is 'Each quiz attempt (0207): the score and whether it reached the pass mark of that day. Retries are kept.';

create table academy_unlocks (
  user_id    uuid not null references users (id) on delete cascade,
  section_id uuid not null references academy_sections (id) on delete cascade,
  unlocked_by uuid not null references users (id),
  reason     text not null check (length(btrim(reason)) between 3 and 300),
  created_at timestamptz not null default now(),
  primary key (user_id, section_id)
);
comment on table academy_unlocks is 'A section an Admin opened early for one person (0207), with the reason.';

-- the content Admins edit and the sections they open early are audited (who, what, before and after); a lesson watched and
-- a quiz attempt are the learner's own records (kept in full, never changed), and a path's section order is in the sections' audit
create trigger audit_academy_paths after insert or update or delete on academy_paths for each row execute function app.audit_row();
create trigger audit_academy_sections after insert or update or delete on academy_sections for each row execute function app.audit_row();
create trigger audit_academy_lessons after insert or update or delete on academy_lessons for each row execute function app.audit_row();
create trigger audit_academy_questions after insert or update or delete on academy_questions for each row execute function app.audit_row();
create trigger audit_academy_unlocks after insert or update or delete on academy_unlocks for each row execute function app.audit_row();

do $$
declare t text;
begin
  foreach t in array array['academy_paths', 'academy_sections', 'academy_path_sections', 'academy_lessons', 'academy_questions', 'academy_lesson_views', 'academy_attempts', 'academy_unlocks'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy admin_all on %I to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('grant select, insert, update, delete on %I to service_role', t);
  end loop;
end $$;

alter table program_settings add column if not exists academy_gate boolean not null default false;
alter table program_settings add column if not exists academy_pass_bps int not null default 8000 check (academy_pass_bps between 5000 and 10000);
comment on column program_settings.academy_gate is 'Academy gate (0207): off (default), the academy records progress only; on, a staff member opens only the academy, the guide and their profile until they pass every path of their functions.';
comment on column program_settings.academy_pass_bps is 'Academy: the share of a quiz''s questions to answer right to pass a section (8000 is 80%).';

-- ================================================================ 2. who takes which path, and where they are
-- the paths of a person: one per staff function held (Sales by its work mode), and Admin for an Admin
create function app.academy_paths_of(p_user uuid) returns text[]
language sql stable security definer set search_path = public, app as $$
  select coalesce(array_agg(distinct p order by p), '{}') from (
    select case f when 'sales' then case when sp.sales_work_mode = 'remote' then 'sales_remote' else 'sales_in_person' end else f end as p
      from staff_profiles sp cross join unnest(sp.functions) f
     where sp.user_id = p_user and sp.is_active and f in ('cs', 'fleet', 'finance', 'sales', 'field')
    union all select 'admin' where app.user_is_admin(p_user)
  ) x
$$;

create function app.academy_passed(p_user uuid, p_section uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from academy_attempts a where a.user_id = p_user and a.section_id = p_section and a.passed)
$$;

-- a section is open on a path when it is the first, when the one before it on the path is passed, or when an Admin opened it
create function app.academy_open(p_user uuid, p_path text, p_section uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from academy_unlocks u where u.user_id = p_user and u.section_id = p_section)
      or app.academy_passed(p_user, p_section)
      or coalesce((select prev.section_id is null or app.academy_passed(p_user, prev.section_id)
                     from academy_path_sections ps
                     left join lateral (select x.section_id from academy_path_sections x where x.path_code = ps.path_code and x.sort < ps.sort order by x.sort desc limit 1) prev on true
                    where ps.path_code = p_path and ps.section_id = p_section), false)
$$;

-- every path of the person passed (a path with no sections counts as passed)
create function app.academy_done(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select not exists (select 1 from academy_path_sections ps where ps.path_code = any (app.academy_paths_of(p_user)) and not app.academy_passed(p_user, ps.section_id))
$$;

-- the gate: on, and a staff member (not an Admin) who has not passed their paths
create function app.academy_locked(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((app.settings()).academy_gate, false) and not app.user_is_admin(p_user)
     and exists (select 1 from user_roles r where r.user_id = p_user and r.role in ('va', 'field'))
     and not app.academy_done(p_user)
$$;

-- the person's progress on one path
create function app.academy_path_progress(p_user uuid, p_path text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('code', p.code, 'title', p.title, 'blurb', p.blurb,
    'sections', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'slug', s.slug, 'title', s.title, 'blurb', s.blurb, 'sort', ps.sort,
        'open', app.academy_open(p_user, p.code, s.id), 'passed', app.academy_passed(p_user, s.id),
        'unlocked_early', exists (select 1 from academy_unlocks u where u.user_id = p_user and u.section_id = s.id),
        'best_bps', (select max(a.score_bps) from academy_attempts a where a.user_id = p_user and a.section_id = s.id),
        'attempts', (select count(*) from academy_attempts a where a.user_id = p_user and a.section_id = s.id),
        'lessons', (select count(*) from academy_lessons l where l.section_id = s.id),
        'viewed', (select count(*) from academy_lesson_views v join academy_lessons l on l.id = v.lesson_id where v.user_id = p_user and l.section_id = s.id),
        'questions', (select count(*) from academy_questions q where q.section_id = s.id)) order by ps.sort)
      from academy_path_sections ps join academy_sections s on s.id = ps.section_id where ps.path_code = p.code), '[]'::jsonb),
    'passed', not exists (select 1 from academy_path_sections ps where ps.path_code = p.code and not app.academy_passed(p_user, ps.section_id)))
  from academy_paths p where p.code = p_path
$$;

-- ================================================================ 3. the staff member's reads and actions
create function app.academy_home(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('paths', coalesce((select jsonb_agg(app.academy_path_progress(p_user, c) order by ap.sort) from unnest(app.academy_paths_of(p_user)) c join academy_paths ap on ap.code = c), '[]'::jsonb),
    'gate', coalesce((app.settings()).academy_gate, false), 'locked', app.academy_locked(p_user), 'pass_bps', (app.settings()).academy_pass_bps)
$$;

-- a section to study: its lessons with their scenes and its questions without the answers; refused while it is closed
create function app.academy_section(p_user uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_path text := p ->> 'path';
  v_sec academy_sections;
begin
  select * into v_sec from academy_sections where slug = p ->> 'section' or id::text = p ->> 'section';
  if v_sec.id is null or not exists (select 1 from academy_path_sections ps where ps.path_code = v_path and ps.section_id = v_sec.id) then raise exception 'No such section' using errcode = 'P0002'; end if;
  if not (v_path = any (app.academy_paths_of(p_user)) or app.user_is_admin(p_user)) then raise exception 'This path is not one of yours' using errcode = '42501'; end if;
  if not app.user_is_admin(p_user) and not app.academy_open(p_user, v_path, v_sec.id) then raise exception 'Pass the section before this one first' using errcode = '42501'; end if;
  return jsonb_build_object('id', v_sec.id, 'slug', v_sec.slug, 'title', v_sec.title, 'blurb', v_sec.blurb, 'path', v_path,
    'path_title', (select title from academy_paths where code = v_path), 'pass_bps', (app.settings()).academy_pass_bps,
    'passed', app.academy_passed(p_user, v_sec.id),
    'best_bps', (select max(a.score_bps) from academy_attempts a where a.user_id = p_user and a.section_id = v_sec.id),
    'next', (select s2.slug from academy_path_sections a join academy_path_sections b on b.path_code = a.path_code and b.sort > a.sort join academy_sections s2 on s2.id = b.section_id
              where a.path_code = v_path and a.section_id = v_sec.id order by b.sort limit 1),
    'lessons', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'title', l.title, 'scenes', l.scenes,
        'viewed', exists (select 1 from academy_lesson_views v where v.user_id = p_user and v.lesson_id = l.id)) order by l.sort) from academy_lessons l where l.section_id = v_sec.id), '[]'::jsonb),
    'questions', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'prompt', q.prompt, 'options', q.options) order by q.sort) from academy_questions q where q.section_id = v_sec.id), '[]'::jsonb));
end $$;

create function app.academy_viewed(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_lesson academy_lessons;
begin
  select * into v_lesson from academy_lessons where id::text = p ->> 'lesson';
  if v_lesson.id is null then raise exception 'No such lesson' using errcode = 'P0002'; end if;
  if not app.user_is_admin(p_user) and not exists (select 1 from academy_path_sections ps where ps.section_id = v_lesson.section_id
      and ps.path_code = any (app.academy_paths_of(p_user)) and app.academy_open(p_user, ps.path_code, ps.section_id)) then
    raise exception 'Pass the section before this one first' using errcode = '42501';
  end if;
  insert into academy_lesson_views (user_id, lesson_id) values (p_user, v_lesson.id) on conflict (user_id, lesson_id) do update set viewed_at = now();
  return jsonb_build_object('ok', true);
end $$;

-- the quiz: graded here (the answers never reach the browser before), kept, and passed at the pass mark
create function app.academy_quiz_submit(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_sec uuid;
  v_total int;
  v_correct int := 0;
  v_bps int;
  v_pass boolean;
  v_results jsonb := '[]'::jsonb;
  q record;
  v_given int;
  v_answers jsonb := coalesce(p -> 'answers', '{}'::jsonb);
begin
  select id into v_sec from academy_sections where id::text = p ->> 'section' or slug = p ->> 'section';
  if v_sec is null then raise exception 'No such section' using errcode = 'P0002'; end if;
  if jsonb_typeof(v_answers) <> 'object' then raise exception 'Give the answers by question' using errcode = '22023'; end if;
  if not app.user_is_admin(p_user) and not exists (select 1 from academy_path_sections ps where ps.section_id = v_sec
      and ps.path_code = any (app.academy_paths_of(p_user)) and app.academy_open(p_user, ps.path_code, ps.section_id)) then
    raise exception 'Pass the section before this one first' using errcode = '42501';
  end if;
  select count(*) into v_total from academy_questions where section_id = v_sec;
  if v_total = 0 then raise exception 'This section has no quiz yet' using errcode = '22023'; end if;
  if exists (select 1 from academy_questions where section_id = v_sec and not (v_answers ? id::text)) then raise exception 'Answer every question' using errcode = '22023'; end if;
  for q in select * from academy_questions where section_id = v_sec order by sort loop
    v_given := case when (v_answers ->> q.id::text) ~ '^\d+$' then (v_answers ->> q.id::text)::int end;
    if v_given = q.answer then v_correct := v_correct + 1; end if;
    v_results := v_results || jsonb_build_object('id', q.id, 'given', v_given, 'answer', q.answer, 'right', v_given = q.answer, 'explain', q.explain);
  end loop;
  v_bps := (v_correct * 10000) / v_total;
  v_pass := v_bps >= coalesce((app.settings()).academy_pass_bps, 8000);
  insert into academy_attempts (user_id, section_id, correct, total, score_bps, passed, answers) values (p_user, v_sec, v_correct, v_total, v_bps, v_pass, v_answers);
  return jsonb_build_object('correct', v_correct, 'total', v_total, 'score_bps', v_bps, 'passed', v_pass, 'pass_bps', (app.settings()).academy_pass_bps, 'results', v_results);
end $$;

-- ================================================================ 4. Admin: progress, opening a section early, editing
create function app.academy_admin_progress(p_user uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.user_is_admin(p_user) then raise exception 'Admins only' using errcode = '42501'; end if;
  if p ? 'user_id' then
    return jsonb_build_object('user', (select jsonb_build_object('id', u.id, 'name', coalesce(u.full_name, u.email), 'email', u.email) from users u where u.id::text = p ->> 'user_id'),
      'paths', coalesce((select jsonb_agg(app.academy_path_progress((p ->> 'user_id')::uuid, c)) from unnest(app.academy_paths_of((p ->> 'user_id')::uuid)) c), '[]'::jsonb),
      'attempts', coalesce((select jsonb_agg(jsonb_build_object('section', s.title, 'score_bps', a.score_bps, 'passed', a.passed, 'at', a.created_at) order by a.created_at desc)
                             from academy_attempts a join academy_sections s on s.id = a.section_id where a.user_id::text = p ->> 'user_id'), '[]'::jsonb));
  end if;
  return jsonb_build_object('staff', coalesce((select jsonb_agg(x order by x ->> 'name') from (
      select jsonb_build_object('id', u.id, 'name', coalesce(u.full_name, u.email), 'email', u.email, 'paths', app.academy_paths_of(u.id),
        'sections', (select count(*) from academy_path_sections ps where ps.path_code = any (app.academy_paths_of(u.id))),
        'passed', (select count(*) from academy_path_sections ps where ps.path_code = any (app.academy_paths_of(u.id)) and app.academy_passed(u.id, ps.section_id)),
        'last', (select max(a.created_at) from academy_attempts a where a.user_id = u.id), 'done', app.academy_done(u.id)) x
        from users u where u.status = 'active' and exists (select 1 from user_roles r where r.user_id = u.id and r.role in ('va', 'field', 'admin'))) t), '[]'::jsonb),
    'gate', coalesce((app.settings()).academy_gate, false));
end $$;

create function app.academy_unlock(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_sec uuid;
begin
  if not app.user_is_admin(p_user) then raise exception 'Admins only' using errcode = '42501'; end if;
  select id into v_sec from academy_sections where id::text = p ->> 'section';
  if v_sec is null then raise exception 'No such section' using errcode = 'P0002'; end if;
  if length(btrim(coalesce(p ->> 'reason', ''))) < 3 then raise exception 'Give the reason' using errcode = '22023'; end if;
  insert into academy_unlocks (user_id, section_id, unlocked_by, reason) values ((p ->> 'user_id')::uuid, v_sec, p_user, btrim(p ->> 'reason'))
    on conflict (user_id, section_id) do update set unlocked_by = excluded.unlocked_by, reason = excluded.reason, created_at = now();
  return jsonb_build_object('ok', true);
end $$;

-- every path with its sections, lessons and questions (answers included), for the editor
create function app.academy_content(p_user uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.user_is_admin(p_user) then raise exception 'Admins only' using errcode = '42501'; end if;
  if p ? 'section' then
    return (select jsonb_build_object('id', s.id, 'slug', s.slug, 'title', s.title, 'blurb', s.blurb,
      'paths', (select coalesce(jsonb_agg(ps.path_code order by ps.path_code), '[]'::jsonb) from academy_path_sections ps where ps.section_id = s.id),
      'lessons', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'sort', l.sort, 'title', l.title, 'scenes', l.scenes) order by l.sort) from academy_lessons l where l.section_id = s.id), '[]'::jsonb),
      'questions', coalesce((select jsonb_agg(jsonb_build_object('id', q.id, 'sort', q.sort, 'prompt', q.prompt, 'options', q.options, 'answer', q.answer, 'explain', q.explain) order by q.sort) from academy_questions q where q.section_id = s.id), '[]'::jsonb))
      from academy_sections s where s.id::text = p ->> 'section');
  end if;
  return jsonb_build_object('paths', coalesce((select jsonb_agg(jsonb_build_object('code', ap.code, 'title', ap.title, 'blurb', ap.blurb,
      'sections', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'slug', s.slug, 'title', s.title, 'sort', ps.sort,
          'lessons', (select count(*) from academy_lessons l where l.section_id = s.id), 'scenes', (select coalesce(sum(jsonb_array_length(l.scenes)), 0) from academy_lessons l where l.section_id = s.id),
          'questions', (select count(*) from academy_questions q where q.section_id = s.id)) order by ps.sort)
        from academy_path_sections ps join academy_sections s on s.id = ps.section_id where ps.path_code = ap.code), '[]'::jsonb)) order by ap.sort) from academy_paths ap), '[]'::jsonb));
end $$;

-- a scene is checked before it is saved: a caption, words to say, a known kind of picture
create function app.academy_check_scenes(p jsonb) returns void
language plpgsql immutable set search_path = public, app as $$
declare s jsonb;
begin
  if jsonb_typeof(p) <> 'array' or jsonb_array_length(p) = 0 then raise exception 'A lesson needs at least one scene' using errcode = '22023'; end if;
  for s in select * from jsonb_array_elements(p) loop
    if jsonb_typeof(s) <> 'object' or length(btrim(coalesce(s ->> 'caption', ''))) = 0 then raise exception 'Each scene needs a caption' using errcode = '22023'; end if;
    if coalesce(s #>> '{visual,kind}', '') not in ('title', 'chat', 'list', 'steps', 'money', 'rule') then raise exception 'Each scene needs a picture: title, chat, list, steps, money or rule' using errcode = '22023'; end if;
  end loop;
end $$;

create function app.academy_save(p_user uuid, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_id uuid;
begin
  if not app.user_is_admin(p_user) then raise exception 'Admins only' using errcode = '42501'; end if;
  if p_name = 'academy_section_save' then
    update academy_sections set title = btrim(p ->> 'title'), blurb = coalesce(p ->> 'blurb', ''), updated_at = now(), updated_by = p_user where id::text = p ->> 'id' returning id into v_id;
  elsif p_name = 'academy_lesson_save' then
    perform app.academy_check_scenes(p -> 'scenes');
    if nullif(p ->> 'id', '') is null then
      insert into academy_lessons (section_id, sort, title, scenes, updated_by)
        values ((p ->> 'section_id')::uuid, coalesce((select max(sort) + 1 from academy_lessons where section_id::text = p ->> 'section_id'), 1), btrim(p ->> 'title'), p -> 'scenes', p_user) returning id into v_id;
    else
      update academy_lessons set title = btrim(p ->> 'title'), scenes = p -> 'scenes', updated_at = now(), updated_by = p_user where id::text = p ->> 'id' returning id into v_id;
    end if;
  elsif p_name = 'academy_question_save' then
    if nullif(p ->> 'id', '') is null then
      insert into academy_questions (section_id, sort, prompt, options, answer, explain, updated_by)
        values ((p ->> 'section_id')::uuid, coalesce((select max(sort) + 1 from academy_questions where section_id::text = p ->> 'section_id'), 1), btrim(p ->> 'prompt'), p -> 'options', (p ->> 'answer')::int, coalesce(p ->> 'explain', ''), p_user) returning id into v_id;
    else
      update academy_questions set prompt = btrim(p ->> 'prompt'), options = p -> 'options', answer = (p ->> 'answer')::int, explain = coalesce(p ->> 'explain', ''), updated_at = now(), updated_by = p_user
       where id::text = p ->> 'id' returning id into v_id;
    end if;
  elsif p_name = 'academy_question_delete' then
    delete from academy_questions where id::text = p ->> 'id' returning id into v_id;
  elsif p_name = 'academy_lesson_delete' then
    delete from academy_lessons where id::text = p ->> 'id' returning id into v_id;
  end if;
  if v_id is null then raise exception 'Nothing to save' using errcode = 'P0002'; end if;
  return jsonb_build_object('id', v_id);
end $$;

-- ================================================================ 5. the door, my_roles, privileges
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0207;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if p_name like 'academy%' and p_call in ('ops_read', 'ops_do', 'admin_read', 'admin_do') then
    perform app.door_begin(p_user, p_aal);
    if not (app.user_is_admin(p_user) or app.user_is_staff(p_user) or app.user_is_field(p_user)) then raise exception 'Staff only' using errcode = '42501'; end if;
    if p_call = 'ops_read' and p_name = 'academy_home' then return app.academy_home(p_user); end if;
    if p_call = 'ops_read' and p_name = 'academy_section' then return app.academy_section(p_user, v); end if;
    if p_call = 'ops_do' and p_name = 'academy_viewed' then return app.academy_viewed(p_user, v); end if;
    if p_call = 'ops_do' and p_name = 'academy_quiz_submit' then return app.academy_quiz_submit(p_user, v); end if;
    if p_call = 'admin_read' and p_name = 'academy_progress' then return app.academy_admin_progress(p_user, v); end if;
    if p_call = 'admin_read' and p_name = 'academy_content' then return app.academy_content(p_user, v); end if;
    if p_call = 'admin_do' and p_name = 'academy_unlock' then return app.academy_unlock(p_user, v); end if;
    if p_call = 'admin_do' and p_name in ('academy_section_save', 'academy_lesson_save', 'academy_question_save', 'academy_question_delete', 'academy_lesson_delete') then return app.academy_save(p_user, p_name, v); end if;
    raise exception 'Unknown academy call %', p_name using errcode = '22023';
  end if;
  return app.door_pre0207(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0207(uuid, text, text, text, jsonb)'::regprocedure);

alter function app.my_roles(uuid) rename to my_roles_pre0207;
create function app.my_roles(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.my_roles_pre0207(p_user) || jsonb_build_object('academy_locked', app.academy_locked(p_user))
$$;
select pg_temp.copy_grants('app.my_roles(uuid)'::regprocedure, 'app.my_roles_pre0207(uuid)'::regprocedure);

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and (p.proname like 'academy%' or p.proname in ('door_pre0207', 'my_roles_pre0207'))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
