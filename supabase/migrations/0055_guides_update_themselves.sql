-- 0055_guides_update_themselves.sql
-- The user guides keep up with the portals by themselves (the owner's request of October 16, 2026). After every
-- successful deploy that changed the portals (web/src) or the guides' own sources, the guides workflow retakes the
-- screenshots on a local stack of the deployed commit, replaces the ones that look different (0049), and then rewrites
-- the text of every section whose screenshot changed or that names a button the portals no longer show: Workers AI,
-- held to facts read from the code of that commit (web/scripts/portal-facts.mjs: the navigation, and the labels of the
-- screens the section shows). A rewrite that passes the checks (every image line kept, every button it names exists,
-- no em dash, a sensible length) is published at once; one that does not is kept as a suggestion to review, as before.
-- Every automatic change keeps the text it replaced: Admin > Settings > Guides shows "Changed automatically on <date>"
-- with a one-click Revert. Then the stored PDFs are printed again (the guides-pdf script, in the same run).
--   1. guide_upkeep_runs: one row per run, with the commit it ran for (the next run compares with it, to skip quickly)
--   2. the automatic change, and its revert
--   3. the guides' admin reads show it
--   4. the server's calls, the door, privileges
--   5. the guides rewritten for this release (the new Admin navigation, Applications, sample photos, the legal review)
-- (docs/changes/2026-10-16-legal-review-admin-redesign.md, section 7.)

-- ================================================================ 1. the runs
create table guide_upkeep_runs (
  id                 uuid primary key default gen_random_uuid(),
  run                text not null unique,                 -- the GitHub run id (or local-<date>)
  sha                text,                                 -- the commit the screenshots were taken of
  status             text not null default 'started' check (status in ('started', 'done', 'failed', 'skipped')),
  images             integer not null default 0,           -- screenshots replaced
  sections_rewritten integer not null default 0,           -- published automatically
  sections_flagged   integer not null default 0,           -- kept as a suggestion to review
  pdfs               integer not null default 0,           -- PDFs printed again
  result             jsonb not null default '{}'::jsonb,
  started_at         timestamptz not null default now(),
  finished_at        timestamptz
);
comment on table guide_upkeep_runs is 'The automatic guide upkeep runs after each deploy (0055): what each changed, and the commit it ran for.';
alter table guide_upkeep_runs enable row level security;
create policy admin_all on guide_upkeep_runs for all to authenticated using (app.is_admin()) with check (app.is_admin());

alter table guide_sections add column if not exists auto_updated_at timestamptz;
alter table guide_sections add column if not exists auto_update_reason text;
alter table guide_sections add column if not exists auto_update_run text;
alter table guide_sections add column if not exists auto_prev jsonb;     -- the text it replaced (title, blurb, body_md, published_md, published_html)
comment on column guide_sections.auto_prev is 'The section as it was before the last automatic change (0055), for the one-click revert.';

-- p: {run, sha, status, images, sections_rewritten, sections_flagged, pdfs, result}. The same run can report more than once.
create or replace function app.guide_upkeep_run_record(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r guide_upkeep_runs;
begin
  if nullif(p ->> 'run', '') is null then raise exception 'The run is missing' using errcode = '22023'; end if;
  insert into guide_upkeep_runs (run, sha, status, images, sections_rewritten, sections_flagged, pdfs, result, finished_at)
  values (p ->> 'run', nullif(p ->> 'sha', ''), coalesce(nullif(p ->> 'status', ''), 'started'), coalesce((p ->> 'images')::integer, 0),
          coalesce((p ->> 'sections_rewritten')::integer, 0), coalesce((p ->> 'sections_flagged')::integer, 0), coalesce((p ->> 'pdfs')::integer, 0),
          coalesce(p -> 'result', '{}'::jsonb), case when coalesce(p ->> 'status', 'started') <> 'started' then now() end)
  on conflict (run) do update set
    sha = coalesce(excluded.sha, guide_upkeep_runs.sha), status = excluded.status,
    images = greatest(guide_upkeep_runs.images, excluded.images),
    sections_rewritten = greatest(guide_upkeep_runs.sections_rewritten, excluded.sections_rewritten),
    sections_flagged = greatest(guide_upkeep_runs.sections_flagged, excluded.sections_flagged),
    pdfs = greatest(guide_upkeep_runs.pdfs, excluded.pdfs),
    result = guide_upkeep_runs.result || excluded.result,
    finished_at = case when excluded.status <> 'started' then now() else guide_upkeep_runs.finished_at end
  returning * into r;
  return to_jsonb(r);
end $$;

-- The commit of the last run that finished: the workflow skips when nothing under web/src or docs/guides changed since.
create or replace function app.guide_upkeep_last_sha() returns text
language sql stable security definer set search_path = public, app as $$
  select sha from guide_upkeep_runs where status = 'done' and sha is not null order by finished_at desc nulls last, started_at desc limit 1
$$;

-- Every section of the published guides, for the run: its text, whether an Admin has a draft waiting, and the
-- screenshots this run replaced in it.
create or replace function app.guide_upkeep_sections(p_run text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'portal', s.portal, 'slug', s.slug, 'kind', s.kind, 'title', s.title,
           'body_md', coalesce(s.published_md, s.body_md), 'draft_waiting', s.body_md is distinct from s.published_md or s.draft_version is distinct from s.published_version,
           'is_hidden', s.is_hidden,
           'images_changed', (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(coalesce(s.review_images, '[]'::jsonb)) e
                               where s.needs_review and (coalesce(p_run, '') = '' or e ->> 'run' = p_run)))
           order by s.portal, s.sort_order), '[]'::jsonb)
    from guide_sections s join guides g on g.portal = s.portal
   where g.version > 0 and s.published_version is not null
$$;

-- ================================================================ 2. the automatic change, and its revert
-- p: {section_id, body_md, html, reason, run, model, neurons, checks_ok, problems}. checks_ok false (or an Admin's draft
-- waiting) keeps the text as a suggestion to review, as 0049 does; otherwise it is published now and the text it
-- replaces is kept for the revert. The guide gets one new version per run, so its PDF shows as older until printed.
create or replace function app.guide_auto_update(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s guide_sections;
  v_body text := p ->> 'body_md';
  v_html text := p ->> 'html';
  v_run text := coalesce(nullif(p ->> 'run', ''), 'manual');
  v_reason text := left(coalesce(nullif(p ->> 'reason', ''), 'The screen changed'), 300);
  v_new integer;
begin
  select * into s from guide_sections where id = (p ->> 'section_id')::uuid for update;
  if s.id is null then raise exception 'Section not found' using errcode = 'P0002'; end if;
  if coalesce(length(v_body), 0) < 10 then raise exception 'The text is missing' using errcode = '22023'; end if;
  insert into provider_calls (provider, purpose, ok, error, duration_ms, cost_microusd, units, unit)
  values (left(coalesce(nullif(p ->> 'model', ''), 'workers-ai'), 120), 'guide_rewrite', true, null, greatest(coalesce((p ->> 'duration_ms')::integer, 0), 0), 0,
          greatest(coalesce((p ->> 'neurons')::integer, 0), 0), 'neurons');
  if v_body = coalesce(s.published_md, s.body_md) then
    update guide_sections set needs_review = false, review_note = null where id = s.id and needs_review;
    return jsonb_build_object('result', 'same', 'section_id', s.id);
  end if;
  if not coalesce((p ->> 'checks_ok')::boolean, false) or s.body_md is distinct from s.published_md or s.draft_version is distinct from s.published_version
     or coalesce(v_html, '') = '' then
    update guide_sections set needs_review = true, review_flagged_at = now(), suggestion_md = v_body, suggestion_at = now(),
           suggestion_model = left(coalesce(nullif(p ->> 'model', ''), 'workers-ai'), 120),
           review_note = left(case when s.body_md is distinct from s.published_md or s.draft_version is distinct from s.published_version
                                   then v_reason || '. An Admin''s draft is waiting, so the new text was not published: compare it with the draft.'
                                   else v_reason || '. The new text did not pass the checks (' || coalesce(p ->> 'problems', 'see the text') || '): read it before you use it.' end, 600)
     where id = s.id;
    return jsonb_build_object('result', 'suggested', 'section_id', s.id);
  end if;
  v_new := s.draft_version + 1;
  update guide_sections
     set auto_prev = jsonb_build_object('title', s.title, 'blurb', s.blurb, 'body_md', s.body_md, 'published_md', s.published_md, 'published_html', s.published_html,
                                        'version', s.published_version),
         body_md = v_body, draft_version = v_new, published_md = v_body, published_html = v_html, published_version = v_new, published_at = now(),
         needs_review = false, review_note = null, suggestion_md = null, suggestion_at = null, suggestion_model = null,
         auto_updated_at = now(), auto_update_reason = v_reason, auto_update_run = v_run
   where id = s.id;
  insert into guide_section_versions (section_id, version, title, blurb, body_md, is_hidden, published)
  select s.id, v_new, s.title, s.blurb, v_body, s.is_hidden, b from (values (false), (true)) v(b)
  on conflict (section_id, version, published) do nothing;
  update guides g set version = version + 1, published_at = now()
   where g.portal = s.portal and g.version > 0
     and not exists (select 1 from audit_log l where l.action = 'guide_auto_update' and l.entity_id = v_run and l.at > now() - interval '1 day'
                       and l.after ->> 'portal' = s.portal);
  insert into audit_log (action, entity_table, entity_id, after)
  values ('guide_auto_update', 'guides', v_run, jsonb_build_object('portal', s.portal, 'section', s.slug, 'reason', v_reason, 'version', v_new));
  return jsonb_build_object('result', 'updated', 'section_id', s.id, 'version', v_new);
end $$;

-- One click in Admin > Settings > Guides: the section shows again the text the automatic change replaced (a new version,
-- published at once, so the history keeps both).
create or replace function app.guide_auto_revert(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s guide_sections;
  v_new integer;
begin
  perform app.assert_admin(p_by);
  select * into s from guide_sections where id = (p ->> 'id')::uuid for update;
  if s.id is null then raise exception 'Section not found' using errcode = 'P0002'; end if;
  if s.auto_prev is null then raise exception 'This section has no automatic change to undo' using errcode = '22023'; end if;
  v_new := s.draft_version + 1;
  update guide_sections
     set title = coalesce(s.auto_prev ->> 'title', title), blurb = s.auto_prev ->> 'blurb',
         body_md = coalesce(s.auto_prev ->> 'published_md', s.auto_prev ->> 'body_md'), draft_version = v_new,
         published_title = coalesce(s.auto_prev ->> 'title', title), published_blurb = s.auto_prev ->> 'blurb',
         published_md = coalesce(s.auto_prev ->> 'published_md', s.auto_prev ->> 'body_md'), published_html = s.auto_prev ->> 'published_html',
         published_version = v_new, published_at = now(), published_by = p_by,
         auto_prev = null, auto_updated_at = null, auto_update_reason = null, auto_update_run = null, needs_review = false, review_note = null,
         updated_by = p_by
   where id = s.id;
  insert into guide_section_versions (section_id, version, title, blurb, body_md, is_hidden, published, saved_by)
  select s.id, v_new, coalesce(s.auto_prev ->> 'title', s.title), s.auto_prev ->> 'blurb', coalesce(s.auto_prev ->> 'published_md', s.auto_prev ->> 'body_md'), s.is_hidden, b, p_by
    from (values (false), (true)) v(b)
  on conflict (section_id, version, published) do nothing;
  update guides set version = version + 1, published_at = now(), published_by = p_by where portal = s.portal;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'guide_auto_revert', 'guide_sections', s.id::text, jsonb_build_object('portal', s.portal, 'section', s.slug, 'version', v_new));
  return jsonb_build_object('section_id', s.id, 'version', v_new);
end $$;

-- ================================================================ 3. the admin reads
alter function app.guide_admin(uuid, text) rename to guide_admin_0049;
create or replace function app.guide_admin(p_by uuid, p_portal text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select r || jsonb_build_object('sections', coalesce((
      select jsonb_agg(x || coalesce((select jsonb_build_object('auto_updated_at', s.auto_updated_at, 'auto_update_reason', s.auto_update_reason,
                                                               'auto_update_run', s.auto_update_run, 'can_revert', s.auto_prev is not null)
                                        from guide_sections s where s.id = (x ->> 'id')::uuid), '{}'::jsonb) order by o)
        from jsonb_array_elements(r -> 'sections') with ordinality t(x, o)), '[]'::jsonb),
    'last_run', (select to_jsonb(u) - 'result' from guide_upkeep_runs u order by u.started_at desc limit 1))
    from app.guide_admin_0049(p_by, p_portal) r
$$;

alter function app.guides_admin(uuid) rename to guides_admin_0049;
create or replace function app.guides_admin(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(g || jsonb_build_object(
           'auto_updated', (select count(*) from guide_sections s where s.portal = g ->> 'portal' and s.auto_prev is not null),
           'auto_updated_at', (select max(s.auto_updated_at) from guide_sections s where s.portal = g ->> 'portal')) order by o), '[]'::jsonb)
    from jsonb_array_elements(app.guides_admin_0049(p_by)) with ordinality t(g, o)
$$;

-- The recent runs, for the card at the top of Admin > Settings > Guides.
create or replace function app.guide_upkeep_runs_read(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return (select coalesce(jsonb_agg(to_jsonb(u) - 'result' order by u.started_at desc), '[]'::jsonb)
            from (select * from guide_upkeep_runs order by started_at desc limit 8) u);
end $$;

-- A chapter new in a release (0055 and later): added after the chapter named, or at the end, published. A chapter that
-- exists is left to app.guide_update_published_section (0049).
create or replace function app.guide_add_published_section(p_portal text, p_slug text, p_kind text, p_after text, p_title text, p_blurb text,
                                                            p_md text, p_html text) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v_order integer;
  v_id uuid;
begin
  if not exists (select 1 from guides where portal = p_portal) then return 'no guide'; end if;
  if exists (select 1 from guide_sections where portal = p_portal and slug = p_slug) then return 'exists'; end if;
  select sort_order into v_order from guide_sections where portal = p_portal and slug = p_after;
  if v_order is null then select coalesce(max(sort_order), 0) into v_order from guide_sections where portal = p_portal and kind <> 'reference'; end if;
  update guide_sections set sort_order = sort_order + 1 where portal = p_portal and sort_order > v_order;
  insert into guide_sections (portal, kind, slug, sort_order, title, blurb, body_md, draft_version, published_title, published_blurb, published_md,
                              published_html, published_version, published_at, is_hidden, published_hidden)
  values (p_portal, p_kind, p_slug, v_order + 1, p_title, p_blurb, p_md, 1, p_title, p_blurb, p_md, p_html, 1, now(), false, false)
  returning id into v_id;
  insert into guide_section_versions (section_id, version, title, blurb, body_md, is_hidden, published)
  select v_id, 1, p_title, p_blurb, p_md, false, b from (values (false), (true)) v(b);
  update guides set version = version + 1, published_at = now() where portal = p_portal and version > 0 and published_at is distinct from now();
  return 'added';
end $$;

-- ================================================================ 4. the server's calls, the door, privileges
create or replace function public.server_guide_upkeep_sections(p_run text) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.guide_upkeep_sections(p_run) $$;
create or replace function public.server_guide_auto_update(p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.guide_auto_update(p) $$;
create or replace function public.server_guide_upkeep_run(p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.guide_upkeep_run_record(p) $$;
create or replace function public.server_guide_upkeep_last_sha() returns text
language sql stable security invoker set search_path = public, app as $$ select app.guide_upkeep_last_sha() $$;

create or replace function app.ops55(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  case p_name
  when 'guide_auto_revert' then return app.guide_auto_revert(p_user, p);
  when 'guide_upkeep_runs' then return app.guide_upkeep_runs_read(p_user);
  else raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_0054;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call = 'ops_read' and p_name = 'guide_upkeep_runs') or (p_call = 'ops_do' and p_name = 'guide_auto_revert') then
    perform app.door_begin(p_user, p_aal);
    return app.ops55(p_user, p_call, p_name, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_0054(p_user, p_aal, p_call, p_name, p);
end $$;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array[
              'guide_upkeep_run_record', 'guide_upkeep_last_sha', 'guide_upkeep_sections', 'guide_auto_update', 'guide_auto_revert', 'guide_admin', 'guides_admin',
              'guide_upkeep_runs_read', 'guide_add_published_section', 'ops55', 'door']))
        or (n.nspname = 'public' and p.proname = any (array['server_guide_upkeep_sections', 'server_guide_auto_update', 'server_guide_upkeep_run', 'server_guide_upkeep_last_sha']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

do $$
declare
  r record;
  v_new regprocedure;
  g text;
begin
  for r in select p.oid, m.new_name, oidvectortypes(p.proargtypes) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             join (values ('door_0054', 'door'), ('guide_admin_0049', 'guide_admin'), ('guides_admin_0049', 'guides_admin')) m(old_name, new_name)
               on m.old_name = p.proname
            where n.nspname = 'app' loop
    v_new := format('app.%I(%s)', r.new_name, r.args)::regprocedure;
    execute format('revoke all on function %s from public, anon, authenticated', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;

-- ================================================================ 5. the guides rewritten for this release
-- From docs/guides/content (docs/guides/src, exported). A chapter still showing the text of the last release (its MD5
-- matches) gets the new text, published; a chapter an Admin edited keeps the Admin's text and gets the new one as a
-- suggestion. New chapters are added. A fresh database has no chapters yet: the seed adds them.
-- A guide text as the portals show it now: every committed screenshot that a guide upkeep run replaced (0049) is shown
-- by its latest replacement, so a release's text never brings an older picture back.
create or replace function app.guide_latest_images(p text) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  r record;
  v text := p;
begin
  if v is null then return null; end if;
  for r in select replaces_url, url from guide_images where replaces_url is not null order by created_at, id loop
    if position(r.replaces_url in v) > 0 then v := replace(v, r.replaces_url, r.url); end if;
  end loop;
  return v;
end $$;

-- A chapter of this release: published when the live chapter still shows the text of the last release (with the
-- screenshots the upkeep replaced), kept as a suggestion when an Admin edited it, added when it is new.
create or replace function app.guide_release_section(p_portal text, p_slug text, p_kind text, p_after text, p_base_md text, p_title text, p_blurb text,
                                                     p_md text, p_html text) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  s guide_sections;
  v_md text := app.guide_latest_images(p_md);
  v_html text := app.guide_latest_images(p_html);
  v_new integer;
begin
  if not exists (select 1 from guides where portal = p_portal) then return 'no guide'; end if;
  select * into s from guide_sections where portal = p_portal and slug = p_slug for update;
  if s.id is null then
    -- a fresh database has no chapters yet (the seed adds them all); a live guide gets the new chapter
    if not exists (select 1 from guide_sections where portal = p_portal) then return 'missing'; end if;
    return app.guide_add_published_section(p_portal, p_slug, p_kind, p_after, p_title, p_blurb, v_md, v_html);
  end if;
  if s.published_md = v_md and s.body_md = v_md then return 'same'; end if;
  if p_base_md is not null and s.published_md is not distinct from app.guide_latest_images(p_base_md)
     and s.body_md = s.published_md and s.published_version is not distinct from s.draft_version then
    v_new := s.draft_version + 1;
    update guide_sections set title = p_title, blurb = p_blurb, body_md = v_md, draft_version = v_new,
           published_title = p_title, published_blurb = p_blurb, published_md = v_md, published_html = v_html, published_version = v_new, published_at = now(),
           needs_review = false, review_note = null
     where id = s.id;
    insert into guide_section_versions (section_id, version, title, blurb, body_md, is_hidden, published)
    select s.id, v_new, p_title, p_blurb, v_md, s.is_hidden, b from (values (false), (true)) v(b)
    on conflict (section_id, version, published) do nothing;
    update guides set version = version + 1, published_at = now() where portal = p_portal and version > 0 and published_at is distinct from now();
    return 'updated';
  end if;
  update guide_sections set needs_review = true, review_flagged_at = now(), suggestion_md = v_md, suggestion_at = now(), suggestion_model = 'CarmaCars (migration 0055)',
         review_note = 'CarmaCars updated this chapter for the new admin menu, owner applications, sample photos and the legal review. Your edited text was kept: compare it with the suggested text and use it, or keep yours.'
   where id = s.id;
  return 'suggested';
end $$;
revoke all on function app.guide_latest_images(text) from public, anon, authenticated;
revoke all on function app.guide_release_section(text, text, text, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function app.guide_latest_images(text) to service_role;
grant execute on function app.guide_release_section(text, text, text, text, text, text, text, text, text) to service_role;

-- GUIDES 0055 START (generated by supabase/seed/0055_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('renter', 'find-a-car-and-send-a-request', 'chapter', 'start-here', 'Every booking starts as a request. A person checks the car and the price, then sends you an offer. Nothing is charged until you approve, sign and pay.

:::flow
Request | You pick a car and dates
Offer | We confirm the price
Sign | The rental agreement
Pay | Your card is authorized
Verify | Licence, selfie, coverage
Pick up | We hand over the keys
:::

## Find a car

Start on carmacars.ca. You do not need to sign in to look around.

1. Go to `carmacars.ca` and press **Find a car**.
2. Add your pickup and return dates. The list then shows the cars that are free and what the whole trip costs.
3. Narrow the list with Filters: type, seats, transmission and daily rate.
4. Open a car to see its photos, rates, what is included and its own calendar.

![](/guides/img/public-02-cars-desktop-b6cd4fb8.jpg "desktop; size: 1440 880; address: carmacars.ca/cars; pins: 1 86.1 4.0, 2 11.1 56.8, 3 3.0 82.3, 4 34.0 87.5")

## Choose your dates on the car page

1. Under Dates and price, tap your pickup date, then your return date. Hatched days are already booked.
2. Choose the Pickup time and the Return time.
3. Want it brought to you? Tick **Deliver it to me** or **Pick it up from me at the end**.
4. Check Your estimate, then press **Request to book**.

![](/guides/img/public-03-car-page-desktop-73be4d63.jpg "desktop; size: 1120 760; address: carmacars.ca/cars/bmw-330i; pins: 1 24.4 39.7, 2 12.9 68.2, 3 3.0 76.2, 4 97.0 50.0")

> Watch out: A request does not hold the car. The car is booked only once you approve the offer, sign and pay.

## Send your request

The request has four short steps. Your answers are saved as you go, so you can come back.

1. Step 1, Dates and delivery: check the car and tap your dates in the calendar.
2. Set the Pickup time and Return time. Any time, day or night, with at least 2 hours of notice.
3. Your request, on the right, shows the estimated total as you go.

![](/guides/img/public-04-book-1-trip-desktop-63a3738b.jpg "desktop; size: 1440 1002; address: carmacars.ca/book/bmw-330i?from=2026-11-23&to=2026-11-26&tf=10:00&tt=10:00; pins: 1 9.2 67.1, 2 15.3 91.0, 3 91.1 54.7")

4. Choose where you get the car: **At our location**, **Deliver it to an address** or **At the airport**. Then choose where you return it.
5. Press **Continue to driver details**.

![](/guides/img/public-04-book-1-trip-desktop-befba4f6.jpg "desktop; size: 760 942; address: carmacars.ca/book/bmw-330i?from=2026-11-23&to=2026-11-26&tf=10:00&tt=10:00; pins: 4 5.3 26.2, 5 61.8 93.3")

6. Step 2, The driver: fill in your first and last name, email, mobile number and date of birth.
7. Someone else will drive too? Add them under Additional drivers. Each needs a G2 or G licence and signs the agreement.
8. Press **Continue to licence**.

![](/guides/img/public-05-book-2-driver-desktop-7b572499.jpg "desktop; size: 980 1032; address: carmacars.ca/book/bmw-330i?from=2026-11-23&to=2026-11-26&tf=10:00&tt=10:00; pins: 6 30.6 21.1, 7 30.6 64.8, 8 55.6 88.0")

9. Step 3: choose your Licence class, for example Ontario G2.
10. Choose how the car is covered: Option 1, 2 or 3. You can change this any time before pickup.
11. Choose the Booking type: Standard, or Non-refundable for 10% off with no refund.
12. Add extras such as Winter tires or Baby seats, and anything we should know.
13. Press **Review request**.

![](/guides/img/public-06-book-3-licence-desktop-22bb144e.jpg "desktop; size: 760 1452; address: carmacars.ca/book/bmw-330i?from=2026-11-23&to=2026-11-26&tf=10:00&tt=10:00; pins: 9 61.8 11.2, 10 92.1 32.2, 11 92.1 50.4, 12 92.1 66.9, 13 71.7 97.0")

14. Step 4, Check it and send: read every line. Use Edit beside a line to change it.
15. Tick the box to confirm you are 18 or older and agree to the Terms of use and Privacy policy.
16. Press **Send request**. Nothing is charged and no card is needed.

![](/guides/img/public-07-book-4-review-desktop-005f4c0b.jpg "desktop; size: 760 492; address: carmacars.ca/book/bmw-330i?from=2026-11-23&to=2026-11-26&tf=10:00&tt=10:00; pins: 14 92.1 24.8, 15 3.9 59.3, 16 73.7 89.0")

17. The confirmation shows your request number, for example CC-10021. Keep it for any question.
18. A person checks the calendar, your dates and your place, usually within 2 hours, day or night. Your offer arrives by email and in Trips.

![](/guides/img/public-08-book-5-sent-phone-14a99ccf.jpg "phone; size: 390 755; pins: 17 32.8 12.3")
', 'Find a car and send a request', 'Search the fleet, pick dates and send a request in four short steps.',
  'Every booking starts as a request. A person checks the car and the price, then sends you an offer. Nothing is charged until you approve, sign and pay.

:::flow
Request | You pick a car and dates
Offer | We confirm the price
Sign | The rental agreement
Pay | Your card is authorized
Verify | Licence, selfie, coverage
Pick up | We hand over the keys
:::

## Find a car

Start on carmacars.ca. You do not need to sign in to look around.

1. Go to `carmacars.ca` and press **Find a car**.
2. Add your pickup and return dates. The list then shows the cars that are free and what the whole trip costs.
3. Narrow the list with Filters: type, seats, transmission and daily rate.
4. Open a car to see its photos, rates, what is included and its own calendar.

![](/guides/img/public-02-cars-desktop-b6cd4fb8.jpg "desktop; size: 1440 880; address: carmacars.ca/cars; pins: 1 86.1 4.0, 2 11.1 56.8, 3 3.0 82.3, 4 34.0 87.5")

## Choose your dates on the car page

1. Under Dates and price, tap your pickup date, then your return date. Hatched days are already booked.
2. Choose the Pickup time and the Return time.
3. Want it brought to you? Tick **Deliver it to me** or **Pick it up from me at the end**.
4. Check Your estimate, then press **Request to book**.

![](/guides/img/public-03-car-page-desktop-73be4d63.jpg "desktop; size: 1120 760; address: carmacars.ca/cars/bmw-330i; pins: 1 24.4 39.7, 2 12.9 68.2, 3 3.0 76.2, 4 97.0 50.0")

> Watch out: A request does not hold the car. The car is booked only once you approve the offer, sign and pay.

## Send your request

The request has four short steps. Your answers are saved as you go, so you can come back.

1. Step 1, Dates and delivery: check the car and tap your dates in the calendar.
2. Set the Pickup time and Return time. Any time, day or night, with at least 2 hours of notice.
3. Your request, on the right, shows the estimated total as you go.

![](/guides/img/public-04-book-1-trip-desktop-63a3738b.jpg "desktop; size: 1440 1002; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 1 9.2 67.1, 2 15.3 91.0, 3 91.1 54.7")

4. Choose where you get the car: **At our location**, **Deliver it to an address** or **At the airport**. Then choose where you return it.
5. Press **Continue to driver details**.

![](/guides/img/public-04-book-1-trip-desktop-befba4f6.jpg "desktop; size: 760 942; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 4 5.3 26.2, 5 61.8 93.3")

6. Step 2, The driver: fill in your first and last name, email, mobile number and date of birth.
7. Someone else will drive too? Add them under Additional drivers. Each needs a G2 or G licence and signs the agreement.
8. Press **Continue to licence**.

![](/guides/img/public-05-book-2-driver-desktop-7b572499.jpg "desktop; size: 980 1032; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 6 30.6 21.1, 7 30.6 64.8, 8 55.6 88.0")

9. Step 3: choose your Licence class, for example Ontario G2.
10. Choose how the car is covered: Option 1 (OPCF 27 on your own auto policy), Option 2 (rental coverage on your credit card) or Option 3 (the CarmaCars Protection Plan). You can change this any time before pickup.
11. Choose the Booking type: Standard, or Non-refundable for 10% off with no refund.
12. Add extras such as Winter tires or Baby seats, and anything we should know.
13. Press **Review request**.

![](/guides/img/public-06-book-3-licence-desktop-22bb144e.jpg "desktop; size: 760 1452; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 9 61.8 11.2, 10 92.1 32.2, 11 92.1 50.4, 12 92.1 66.9, 13 71.7 97.0")

14. Step 4, Check it and send: read every line. Use Edit beside a line to change it.
15. Tick the box to confirm you are 18 or older and agree to the Terms of use and Privacy policy.
16. Press **Send request**. Nothing is charged and no card is needed.

![](/guides/img/public-07-book-4-review-desktop-005f4c0b.jpg "desktop; size: 760 492; address: carmacars.ca/book/bmw-330i?from=2026-11-25&to=2026-11-28&tf=10:00&tt=10:00; pins: 14 92.1 24.8, 15 3.9 59.3, 16 73.7 89.0")

17. The confirmation shows your request number, for example CC-10021. Keep it for any question.
18. A person checks the calendar, your dates and your place, usually within 2 hours, day or night. Your offer arrives by email and in Trips.

![](/guides/img/public-08-book-5-sent-phone-14a99ccf.jpg "phone; size: 390 755; pins: 17 32.8 12.3")
',
  '<p class="gd-p">Every booking starts as a request. A person checks the car and the price, then sends you an offer. Nothing is charged until you approve, sign and pay.</p><ol class="gd-flow"><li><b>1</b><span>Request</span><em>You pick a car and dates</em></li><li><b>2</b><span>Offer</span><em>We confirm the price</em></li><li><b>3</b><span>Sign</span><em>The rental agreement</em></li><li><b>4</b><span>Pay</span><em>Your card is authorized</em></li><li><b>5</b><span>Verify</span><em>Licence, selfie, coverage</em></li><li><b>6</b><span>Pick up</span><em>We hand over the keys</em></li></ol><section class="gd-task" id="find-a-car-and-send-a-request-find-a-car" data-gd-task><h2 class="gd-h2">Find a car</h2><p class="gd-p">Start on carmacars.ca. You do not need to sign in to look around.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Go to <span class="gd-url">carmacars.ca</span> and press <b class="gd-ui">Find a car</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Add your pickup and return dates. The list then shows the cars that are free and what the whole trip costs.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Narrow the list with Filters: type, seats, transmission and daily rate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Open a car to see its photos, rates, what is included and its own calendar.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/cars</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/880"><img src="/guides/img/public-02-cars-desktop-b6cd4fb8.jpg" alt="" loading="lazy" decoding="async" width="1440" height="880"><span class="gd-pin" style="left:86.1%;top:4%" aria-hidden="true">1</span><span class="gd-pin" style="left:11.1%;top:56.8%" aria-hidden="true">2</span><span class="gd-pin" style="left:3%;top:82.3%" aria-hidden="true">3</span><span class="gd-pin" style="left:34%;top:87.5%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="find-a-car-and-send-a-request-choose-your-dates-on-the-car-page" data-gd-task><h2 class="gd-h2">Choose your dates on the car page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Under Dates and price, tap your pickup date, then your return date. Hatched days are already booked.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the Pickup time and the Return time.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Want it brought to you? Tick <b class="gd-ui">Deliver it to me</b> or <b class="gd-ui">Pick it up from me at the end</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Check Your estimate, then press <b class="gd-ui">Request to book</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/cars/bmw-330i</span></div><div class="gd-imgwrap" style="aspect-ratio:1120/760"><img src="/guides/img/public-03-car-page-desktop-73be4d63.jpg" alt="" loading="lazy" decoding="async" width="1120" height="760"><span class="gd-pin" style="left:24.4%;top:39.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:12.9%;top:68.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:3%;top:76.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:97%;top:50%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>A request does not hold the car. The car is booked only once you approve the offer, sign and pay.</div></aside></section><section class="gd-task" id="find-a-car-and-send-a-request-send-your-request" data-gd-task><h2 class="gd-h2">Send your request</h2><p class="gd-p">The request has four short steps. Your answers are saved as you go, so you can come back.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Step 1, Dates and delivery: check the car and tap your dates in the calendar.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Set the Pickup time and Return time. Any time, day or night, with at least 2 hours of notice.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Your request, on the right, shows the estimated total as you go.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1002"><img src="/guides/img/public-04-book-1-trip-desktop-63a3738b.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1002"><span class="gd-pin" style="left:9.2%;top:67.1%" aria-hidden="true">1</span><span class="gd-pin" style="left:15.3%;top:91%" aria-hidden="true">2</span><span class="gd-pin" style="left:91.1%;top:54.7%" aria-hidden="true">3</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="4"><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Choose where you get the car: <b class="gd-ui">At our location</b>, <b class="gd-ui">Deliver it to an address</b> or <b class="gd-ui">At the airport</b>. Then choose where you return it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Continue to driver details</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:760/942"><img src="/guides/img/public-04-book-1-trip-desktop-befba4f6.jpg" alt="" loading="lazy" decoding="async" width="760" height="942"><span class="gd-pin" style="left:5.3%;top:26.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:61.8%;top:93.3%" aria-hidden="true">5</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="6"><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Step 2, The driver: fill in your first and last name, email, mobile number and date of birth.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Someone else will drive too? Add them under Additional drivers. Each needs a G2 or G licence and signs the agreement.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Press <b class="gd-ui">Continue to licence</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:980/1032"><img src="/guides/img/public-05-book-2-driver-desktop-7b572499.jpg" alt="" loading="lazy" decoding="async" width="980" height="1032"><span class="gd-pin" style="left:30.6%;top:21.1%" aria-hidden="true">6</span><span class="gd-pin" style="left:30.6%;top:64.8%" aria-hidden="true">7</span><span class="gd-pin" style="left:55.6%;top:88%" aria-hidden="true">8</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="9"><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Step 3: choose your Licence class, for example Ontario G2.</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Choose how the car is covered: Option 1 (OPCF 27 on your own auto policy), Option 2 (rental coverage on your credit card) or Option 3 (the CarmaCars Protection Plan). You can change this any time before pickup.</div></li><li><span class="gd-n" aria-hidden="true">11</span><div class="gd-t">Choose the Booking type: Standard, or Non-refundable for 10% off with no refund.</div></li><li><span class="gd-n" aria-hidden="true">12</span><div class="gd-t">Add extras such as Winter tires or Baby seats, and anything we should know.</div></li><li><span class="gd-n" aria-hidden="true">13</span><div class="gd-t">Press <b class="gd-ui">Review request</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:760/1452"><img src="/guides/img/public-06-book-3-licence-desktop-22bb144e.jpg" alt="" loading="lazy" decoding="async" width="760" height="1452"><span class="gd-pin" style="left:61.8%;top:11.2%" aria-hidden="true">9</span><span class="gd-pin" style="left:92.1%;top:32.2%" aria-hidden="true">10</span><span class="gd-pin" style="left:92.1%;top:50.4%" aria-hidden="true">11</span><span class="gd-pin" style="left:92.1%;top:66.9%" aria-hidden="true">12</span><span class="gd-pin" style="left:71.7%;top:97%" aria-hidden="true">13</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="14"><li><span class="gd-n" aria-hidden="true">14</span><div class="gd-t">Step 4, Check it and send: read every line. Use Edit beside a line to change it.</div></li><li><span class="gd-n" aria-hidden="true">15</span><div class="gd-t">Tick the box to confirm you are 18 or older and agree to the Terms of use and Privacy policy.</div></li><li><span class="gd-n" aria-hidden="true">16</span><div class="gd-t">Press <b class="gd-ui">Send request</b>. Nothing is charged and no card is needed.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/book/bmw-330i?from=2026-11-25&amp;to=2026-11-28&amp;tf=10:00&amp;tt=10:00</span></div><div class="gd-imgwrap" style="aspect-ratio:760/492"><img src="/guides/img/public-07-book-4-review-desktop-005f4c0b.jpg" alt="" loading="lazy" decoding="async" width="760" height="492"><span class="gd-pin" style="left:92.1%;top:24.8%" aria-hidden="true">14</span><span class="gd-pin" style="left:3.9%;top:59.3%" aria-hidden="true">15</span><span class="gd-pin" style="left:73.7%;top:89%" aria-hidden="true">16</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol" start="17"><li><span class="gd-n" aria-hidden="true">17</span><div class="gd-t">The confirmation shows your request number, for example CC-10021. Keep it for any question.</div></li><li><span class="gd-n" aria-hidden="true">18</span><div class="gd-t">A person checks the calendar, your dates and your place, usually within 2 hours, day or night. Your offer arrives by email and in Trips.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/755"><img src="/guides/img/public-08-book-5-sent-phone-14a99ccf.jpg" alt="" loading="lazy" decoding="async" width="390" height="755"><span class="gd-pin" style="left:32.8%;top:12.3%" aria-hidden="true">17</span></div></div></figure></div></section>');
select app.guide_release_section('renter', 'your-offer', 'chapter', 'find-a-car-and-send-a-request', 'Our offer is the confirmed price for your car and dates, with every fee and HST. It stays open for 24 hours. You approve it, ask for a change or decline it.

## Open your offer

1. We email you when the offer is ready. Sign in at `carmacars.ca/sign-in` and open **Trips**.
2. Your next step is always at the top. Press **Review offer**.

![](/guides/img/renter-02-trips-offer-desktop-27603c14.jpg "desktop; size: 1440 760; address: carmacars.ca/account; pins: 1 4.5 27.0, 2 11.5 70.0")

## Approve, ask for a change, or decline

1. Check the price, the dates, the place and any message from our team. The black bar shows how long the offer stays open.
2. All good? Press **Approve and continue** to sign and pay.
3. Want something different? Press **Ask for a change**, write what you need, then **Send request**.
4. Not going ahead? Press **Decline offer**, then **Decline this offer**.

![](/guides/img/renter-03-offer-desktop-cae88b00.jpg "desktop; size: 1440 902; address: carmacars.ca/account/bookings/CC-10021/offer; pins: 1 86.1 12.0, 2 70.8 50.9, 3 70.8 58.1, 4 77.1 64.5")

> Watch out: This offer does not hold the car. If someone else approves, signs and pays for the same car and dates first, we tell you and offer you another car or other dates.
', 'Your offer', 'Read the confirmed price, then approve, ask for a change or decline.',
  'Our offer is the confirmed price for your car and dates, with every fee and HST. It stays open for 24 hours. You approve it, ask for a change or decline it.

## Open your offer

1. We email you when the offer is ready. Sign in at `carmacars.ca/sign-in` and open **Trips**.
2. Your next step is always at the top. Press **Review offer**.

![](/guides/img/renter-02-trips-offer-desktop-27603c14.jpg "desktop; size: 1440 760; address: carmacars.ca/account; pins: 1 4.5 27.0, 2 11.5 70.0")

## Approve, ask for a change, or decline

1. Check the price, the dates, the place and any message from our team. The black bar shows how long the offer stays open.
2. All good? Press **Approve and continue** to sign and pay.
3. Want something different? Press **Ask for a change**, write what you need, then **Send request**.
4. Not going ahead? Press **Decline offer**, then **Decline this offer**.

![](/guides/img/renter-03-offer-desktop-cae88b00.jpg "desktop; size: 1440 902; address: carmacars.ca/account/bookings/CC-10057/offer; pins: 1 86.1 12.0, 2 70.8 50.9, 3 70.8 58.1, 4 77.1 64.5")

> Watch out: This offer does not hold the car. If someone else approves, signs and pays for the same car and dates first, we tell you and offer you another car or other dates.
',
  '<p class="gd-p">Our offer is the confirmed price for your car and dates, with every fee and HST. It stays open for 24 hours. You approve it, ask for a change or decline it.</p><section class="gd-task" id="your-offer-open-your-offer" data-gd-task><h2 class="gd-h2">Open your offer</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">We email you when the offer is ready. Sign in at <span class="gd-url">carmacars.ca/sign-in</span> and open <b class="gd-ui">Trips</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Your next step is always at the top. Press <b class="gd-ui">Review offer</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/760"><img src="/guides/img/renter-02-trips-offer-desktop-27603c14.jpg" alt="" loading="lazy" decoding="async" width="1440" height="760"><span class="gd-pin" style="left:4.5%;top:27%" aria-hidden="true">1</span><span class="gd-pin" style="left:11.5%;top:70%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="your-offer-approve-ask-for-a-change-or-decline" data-gd-task><h2 class="gd-h2">Approve, ask for a change, or decline</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Check the price, the dates, the place and any message from our team. The black bar shows how long the offer stays open.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">All good? Press <b class="gd-ui">Approve and continue</b> to sign and pay.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Want something different? Press <b class="gd-ui">Ask for a change</b>, write what you need, then <b class="gd-ui">Send request</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Not going ahead? Press <b class="gd-ui">Decline offer</b>, then <b class="gd-ui">Decline this offer</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10057/offer</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/902"><img src="/guides/img/renter-03-offer-desktop-cae88b00.jpg" alt="" loading="lazy" decoding="async" width="1440" height="902"><span class="gd-pin" style="left:86.1%;top:12%" aria-hidden="true">1</span><span class="gd-pin" style="left:70.8%;top:50.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:70.8%;top:58.1%" aria-hidden="true">3</span><span class="gd-pin" style="left:77.1%;top:64.5%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>This offer does not hold the car. If someone else approves, signs and pays for the same car and dates first, we tell you and offer you another car or other dates.</div></aside></section>');
select app.guide_release_section('renter', 'sign-and-pay', 'chapter', 'your-offer', 'After you approve, you sign the rental agreement on screen and pay. It takes a few minutes on a phone or a computer; the signing itself is three taps.

## Sign the rental agreement

1. Fill in your home address and licence details. You do this once; we keep them for next time.
2. Press **Save details**. The agreement then shows your details.

![](/guides/img/renter-04-sign-details-desktop-bd193670.jpg "desktop; size: 1440 1052; address: carmacars.ca/account/bookings/CC-10021/sign; pins: 1 44.4 25.9, 2 16.3 96.4")

3. Check the key values at the top: the car, the dates, the deposit and the deductible. Open **Read the full rental agreement** to read it word for word, or press **Download PDF** to keep a copy.
4. Under Sign, tap **All four**: it ticks the four statements, which stay on screen to read.
5. Your full legal name is your signature. Prefer to sign with your finger or the mouse? Press **Draw instead**.
6. Press **Sign and continue to payment**.

![](/guides/img/renter-06-sign-ready-desktop-1eee20a4.jpg "desktop; size: 1440 1212; address: carmacars.ca/account/bookings/CC-10021/sign; pins: 3 59.0 8.9, 4 69.4 18.2, 5 90.3 78.5, 6 96.9 87.1")

## Pay to confirm

1. Check What you pay now. The refundable deposit is taken at pickup, not today.
2. Enter the Name on the card and the card details. Use a credit card in your own name.
3. Press **Pay $...** (the button shows the amount).

![](/guides/img/renter-07-pay-desktop-705896d6.jpg "desktop; size: 1440 1082; address: carmacars.ca/account/bookings/CC-10021/pay; pins: 7 70.5 21.9, 8 64.6 16.5, 9 64.6 96.4")

> Tip: Your card is authorized now and charged once the booking is confirmed. It becomes your Card on File for the deposit at pickup and any later charges you agreed to when you signed.

> Watch out: See "This car was just taken"? Someone confirmed the same car first. The authorization on your card is released, and we offer you another car or other dates.
', 'Sign and pay', 'Sign the rental agreement on screen and pay with your card.',
  'After you approve, you sign the rental agreement on screen and pay. It takes a few minutes on a phone or a computer; the signing itself is three taps.

## Sign the rental agreement

1. Fill in your home address and licence details. You do this once; we keep them for next time.
2. Press **Save details**. The agreement then shows your details.

![](/guides/img/renter-04-sign-details-desktop-bd193670.jpg "desktop; size: 1440 1052; address: carmacars.ca/account/bookings/CC-10057/sign; pins: 1 44.4 25.9, 2 16.3 96.4")

3. Check the key values at the top: the car, the dates, the deposit and the deductible. Open **Read the full rental agreement** to read it word for word, or press **Download PDF** to keep a copy.
4. Under Sign, tap **All four**: it ticks the four statements, which stay on screen to read.
5. Your full legal name is your signature. Prefer to sign with your finger or the mouse? Press **Draw instead**.
6. Press **Sign and continue to payment**.

![](/guides/img/renter-06-sign-ready-desktop-1eee20a4.jpg "desktop; size: 1440 1212; address: carmacars.ca/account/bookings/CC-10057/sign; pins: 3 59.0 8.9, 4 69.4 18.2, 5 90.3 78.5, 6 96.9 87.1")

## Pay to confirm

1. Check What you pay now. The refundable deposit is taken at pickup, not today.
2. Enter the Name on the card and the card details. Use a credit card in your own name.
3. Press **Pay $...** (the button shows the amount).

![](/guides/img/renter-07-pay-desktop-705896d6.jpg "desktop; size: 1440 1082; address: carmacars.ca/account/bookings/CC-10057/pay; pins: 7 70.5 21.9, 8 64.6 16.5, 9 64.6 96.4")

> Tip: Your card is authorized now and charged once the booking is confirmed. It becomes your Card on File for the deposit at pickup and any later charges you agreed to when you signed.

> Watch out: See "This car was just taken"? Someone confirmed the same car first. The authorization on your card is released, and we offer you another car or other dates.

## A rental we booked for you

Booked by phone, in person or through a partner? We add the rental and you sign it online.

1. You get an email: "Read and sign your rental agreement; your card is charged when you sign."
2. Open it. Check the car, the dates and the price, and read the agreement.
3. Press **Accept and sign**. If we have your card on file, it is charged at that moment, not before, and the agreement is countersigned by CarmaCars as soon as you sign.
',
  '<p class="gd-p">After you approve, you sign the rental agreement on screen and pay. It takes a few minutes on a phone or a computer; the signing itself is three taps.</p><section class="gd-task" id="sign-and-pay-sign-the-rental-agreement" data-gd-task><h2 class="gd-h2">Sign the rental agreement</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Fill in your home address and licence details. You do this once; we keep them for next time.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Save details</b>. The agreement then shows your details.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10057/sign</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1052"><img src="/guides/img/renter-04-sign-details-desktop-bd193670.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1052"><span class="gd-pin" style="left:44.4%;top:25.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:16.3%;top:96.4%" aria-hidden="true">2</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check the key values at the top: the car, the dates, the deposit and the deductible. Open <b class="gd-ui">Read the full rental agreement</b> to read it word for word, or press <b class="gd-ui">Download PDF</b> to keep a copy.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Under Sign, tap <b class="gd-ui">All four</b>: it ticks the four statements, which stay on screen to read.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Your full legal name is your signature. Prefer to sign with your finger or the mouse? Press <b class="gd-ui">Draw instead</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Press <b class="gd-ui">Sign and continue to payment</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10057/sign</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1212"><img src="/guides/img/renter-06-sign-ready-desktop-1eee20a4.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1212"><span class="gd-pin" style="left:59%;top:8.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:69.4%;top:18.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:90.3%;top:78.5%" aria-hidden="true">5</span><span class="gd-pin" style="left:96.9%;top:87.1%" aria-hidden="true">6</span></div></div></figure></div></section><section class="gd-task" id="sign-and-pay-pay-to-confirm" data-gd-task><h2 class="gd-h2">Pay to confirm</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Check What you pay now. The refundable deposit is taken at pickup, not today.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Enter the Name on the card and the card details. Use a credit card in your own name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Pay $...</b> (the button shows the amount).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10057/pay</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1082"><img src="/guides/img/renter-07-pay-desktop-705896d6.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1082"><span class="gd-pin" style="left:70.5%;top:21.9%" aria-hidden="true">7</span><span class="gd-pin" style="left:64.6%;top:16.5%" aria-hidden="true">8</span><span class="gd-pin" style="left:64.6%;top:96.4%" aria-hidden="true">9</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Your card is authorized now and charged once the booking is confirmed. It becomes your Card on File for the deposit at pickup and any later charges you agreed to when you signed.</div></aside><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>See &quot;This car was just taken&quot;? Someone confirmed the same car first. The authorization on your card is released, and we offer you another car or other dates.</div></aside></section><section class="gd-task" id="sign-and-pay-a-rental-we-booked-for-you" data-gd-task><h2 class="gd-h2">A rental we booked for you</h2><p class="gd-p">Booked by phone, in person or through a partner? We add the rental and you sign it online.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">You get an email: &quot;Read and sign your rental agreement; your card is charged when you sign.&quot;</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open it. Check the car, the dates and the price, and read the agreement.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Accept and sign</b>. If we have your card on file, it is charged at that moment, not before, and the agreement is countersigned by CarmaCars as soon as you sign.</div></li></ol></div></section>');
select app.guide_release_section('renter', 'before-pickup', 'chapter', 'sign-and-pay', 'Your booking is confirmed. A few things are left: your licence photos, a selfie and proof of coverage, a signature from each additional driver, and the deposit.

## Your booking page

1. Open **Trips**, then your booking. The status is at the top, for example Confirmed.
2. The red card tells you what is still needed before pickup.
3. Progress shows each stage, from Request sent to Statement.
4. Need something else? holds **Licence and coverage**, **Ask to change dates**, **Cancel booking** and **Extend**.

![](/guides/img/renter-08-booking-confirmed-desktop-125011fd.jpg "desktop; size: 1440 1032; address: carmacars.ca/account/bookings/CC-10021; pins: 1 15.6 9.1, 2 18.1 36.5, 3 8.1 56.8, 4 96.5 79.9")

## Upload your licence, selfie and coverage

Do this at least 24 hours before pickup. It takes a few minutes with your phone.

1. On your booking, press **Upload documents** (or **Licence and coverage**).
2. Licence, front: lay the licence on a dark surface with all four corners visible. Press **Take photo**.
3. Licence, back: do the same for the back.
4. Selfie with your licence: hold the licence beside your face, then press **Take selfie**.
5. Coverage for damage to the car: add what your option asks for, then press **Upload proof**.

![](/guides/img/renter-09-verify-desktop-d20f668d.jpg "desktop; size: 1440 1232; address: carmacars.ca/account/bookings/CC-10021/verify; pins: 2 18.5 65.3, 3 50.0 63.6, 4 81.2 63.6, 5 50.0 95.3")

> Tip: For Option 2 (your credit card coverage), add the card issuer, the last four digits and the card benefits certificate. It must be the card you paid with. We delete licence and face photos 90 days after your rental ends.

## Additional drivers

Each additional driver signs the agreement with their own link.

1. When the agreement is ready, each driver with an email gets their own signing link.
2. On your booking, press **Copy their signing link** to send it yourself, or **Send a new link**.
3. Each driver adds their own licence photos and selfie, like you did.

> Watch out: Signing links expire after 72 hours. A new link ends the older one, so always send the newest.

## What to bring to pickup

- Your original licence. A photo is not enough.
- The card you paid with. The deposit is taken on it about an hour before pickup.
- A few minutes to walk around the car with us. We photograph it together.
', 'Before pickup', 'Upload your licence and coverage, send driver links, and know what to bring.',
  'Your booking is confirmed. A few things are left: your licence photos, a selfie and proof of coverage, a signature from each additional driver, and the deposit.

## Your booking page

1. Open **Trips**, then your booking. The status is at the top, for example Confirmed.
2. The red card tells you what is still needed before pickup.
3. Progress shows each stage, from Request sent to Statement.
4. Need something else? holds **Licence and coverage**, **Ask to change dates**, **Cancel booking** and **Extend**.

![](/guides/img/renter-08-booking-confirmed-desktop-125011fd.jpg "desktop; size: 1440 1032; address: carmacars.ca/account/bookings/CC-10057; pins: 1 15.6 9.1, 2 18.1 36.5, 3 8.1 56.8, 4 96.5 79.9")

## Upload your licence, selfie and coverage

Do this at least 24 hours before pickup. It takes a few minutes with your phone.

1. On your booking, press **Upload documents** (or **Licence and coverage**).
2. Licence, front: lay the licence on a dark surface with all four corners visible. Press **Take photo**.
3. Licence, back: do the same for the back.
4. Selfie with your licence: hold the licence beside your face, then press **Take selfie**.
5. Coverage for damage to the car: add what your option asks for, then press **Upload proof**.

![](/guides/img/renter-09-verify-desktop-d20f668d.jpg "desktop; size: 1440 1232; address: carmacars.ca/account/bookings/CC-10057/verify; pins: 2 18.5 65.3, 3 50.0 63.6, 4 81.2 63.6, 5 50.0 95.3")

> Tip: For Option 1, add the policy page or insurer letter that shows OPCF 27. For Option 2 (your credit card coverage), add the card issuer, the last four digits and the card benefits certificate; it must be the card you paid with. For Option 3, we send the Protection Plan''s terms and activate it once it is paid. We delete licence and face photos 90 days after your rental ends.

## Additional drivers

Each additional driver signs the agreement with their own link.

1. When the agreement is ready, each driver with an email gets their own signing link.
2. On your booking, press **Copy their signing link** to send it yourself, or **Send a new link**.
3. Each driver adds their own licence photos and selfie, like you did.

> Watch out: Signing links expire after 72 hours. A new link ends the older one, so always send the newest.

## What to bring to pickup

- Your original licence. A photo is not enough.
- The card you paid with. The deposit is taken on it about an hour before pickup.
- A few minutes to walk around the car with us. We photograph it together.
',
  '<p class="gd-p">Your booking is confirmed. A few things are left: your licence photos, a selfie and proof of coverage, a signature from each additional driver, and the deposit.</p><section class="gd-task" id="before-pickup-your-booking-page" data-gd-task><h2 class="gd-h2">Your booking page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Trips</b>, then your booking. The status is at the top, for example Confirmed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The red card tells you what is still needed before pickup.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Progress shows each stage, from Request sent to Statement.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Need something else? holds <b class="gd-ui">Licence and coverage</b>, <b class="gd-ui">Ask to change dates</b>, <b class="gd-ui">Cancel booking</b> and <b class="gd-ui">Extend</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10057</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1032"><img src="/guides/img/renter-08-booking-confirmed-desktop-125011fd.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1032"><span class="gd-pin" style="left:15.6%;top:9.1%" aria-hidden="true">1</span><span class="gd-pin" style="left:18.1%;top:36.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:8.1%;top:56.8%" aria-hidden="true">3</span><span class="gd-pin" style="left:96.5%;top:79.9%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="before-pickup-upload-your-licence-selfie-and-coverage" data-gd-task><h2 class="gd-h2">Upload your licence, selfie and coverage</h2><p class="gd-p">Do this at least 24 hours before pickup. It takes a few minutes with your phone.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On your booking, press <b class="gd-ui">Upload documents</b> (or <b class="gd-ui">Licence and coverage</b>).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Licence, front: lay the licence on a dark surface with all four corners visible. Press <b class="gd-ui">Take photo</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Licence, back: do the same for the back.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Selfie with your licence: hold the licence beside your face, then press <b class="gd-ui">Take selfie</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Coverage for damage to the car: add what your option asks for, then press <b class="gd-ui">Upload proof</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10057/verify</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1232"><img src="/guides/img/renter-09-verify-desktop-d20f668d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1232"><span class="gd-pin" style="left:18.5%;top:65.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:50%;top:63.6%" aria-hidden="true">3</span><span class="gd-pin" style="left:81.2%;top:63.6%" aria-hidden="true">4</span><span class="gd-pin" style="left:50%;top:95.3%" aria-hidden="true">5</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>For Option 1, add the policy page or insurer letter that shows OPCF 27. For Option 2 (your credit card coverage), add the card issuer, the last four digits and the card benefits certificate; it must be the card you paid with. For Option 3, we send the Protection Plan&#39;s terms and activate it once it is paid. We delete licence and face photos 90 days after your rental ends.</div></aside></section><section class="gd-task" id="before-pickup-additional-drivers" data-gd-task><h2 class="gd-h2">Additional drivers</h2><p class="gd-p">Each additional driver signs the agreement with their own link.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When the agreement is ready, each driver with an email gets their own signing link.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">On your booking, press <b class="gd-ui">Copy their signing link</b> to send it yourself, or <b class="gd-ui">Send a new link</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each driver adds their own licence photos and selfie, like you did.</div></li></ol></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Signing links expire after 72 hours. A new link ends the older one, so always send the newest.</div></aside></section><section class="gd-task" id="before-pickup-what-to-bring-to-pickup" data-gd-task><h2 class="gd-h2">What to bring to pickup</h2><ul class="gd-ul"><li>Your original licence. A photo is not enough.</li><li>The card you paid with. The deposit is taken on it about an hour before pickup.</li><li>A few minutes to walk around the car with us. We photograph it together.</li></ul></section>');
select app.guide_release_section('renter', 'during-your-trip', 'chapter', 'before-pickup', 'Plans change. You can ask for more days, ask to change dates, answer a change we suggest, or cancel, all from your booking.

## Extend your rental

1. On your booking, press **Extend**.
2. Choose the new return date and time, then press **See the price**.
3. Press **Request extension**. Once we approve it, press **Pay for the extension** before your current return time.

![](/guides/img/renter-11-extend-desktop-957274cc.jpg "desktop; size: 960 552; address: carmacars.ca/account/bookings/CC-10021/extend; pins: 2 34.4 62.9, 3 15.1 77.2")

> Watch out: Ask before your current return time. One rental can be at most 30 days.

## Ask to change dates

1. On your booking, press **Ask to change dates**.
2. Set the new pickup and return, then press **See the difference** to see what you would pay or get back.
3. Press **Ask to change dates** to send it. Nothing changes until you agree to our answer.

![](/guides/img/renter-12-change-desktop-09f6b563.jpg "desktop; size: 960 552; address: carmacars.ca/account/bookings/CC-10021/change; pins: 2 15.1 91.8")

## A change we suggest

Sometimes we need to change your booking, for example another car of the same class. You decide.

1. You get an email, and your booking says "We suggest a change to your booking". Press **Review and answer**.
2. Read what changes (before and after), the reason, the money and the time left to answer.
3. To agree, press **Accept and sign the amendment**, sign, then press **Accept and sign**.
4. Anything more to pay is charged to your Card on File. If the card is declined, press **Pay and apply the change**.
5. To say no, press **Decline this change**. Your booking stays as it was.

> Tip: You have 48 hours to answer, and we send one reminder. The signed amendment is saved under Documents.

## Cancel a booking

1. On your booking, press **Cancel booking**.
2. Read What you get back. It shows the rule that applies and your refund.
3. Type the booking number to confirm (for example CC-10021), then press **Cancel booking**.

![](/guides/img/renter-13-cancel-desktop-d0bb2c67.jpg "desktop; size: 1440 692; address: carmacars.ca/account/bookings/CC-10021/cancel; pins: 2 36.1 67.2, 3 95.8 45.1")

| Standard booking: when you cancel | Refund of what you paid |
| --- | --- |
| Within 24 hours of booking, and 48 hours or more before pickup | 95% back |
| 48 hours or more before pickup | 75% back |
| 24 to 48 hours before pickup | 50% back |
| Less than 24 hours before pickup | No refund |

A Non-refundable booking gets no refund. The deposit is taken at pickup, so none is held when you cancel before it.

## Messages, tolls and tickets

- Write to us about a booking at the bottom of its page: type in Your message and press Send.
- Tolls and tickets are yours to pay, including Highway 407 ETR. If one reaches us, we pay it and charge the amount plus our fee to your Card on File, and email you a copy of the notice.
- Running late? Ask to extend before your return time, or call us at 647-575-3377.
', 'During your trip', 'Extend, change dates, answer a change we suggest, or cancel.',
  'Plans change. You can ask for more days, ask to change dates, answer a change we suggest, or cancel, all from your booking.

## Extend your rental

1. On your booking, press **Extend**.
2. Choose the new return date and time, then press **See the price**.
3. Press **Request extension**. Once we approve it, press **Pay for the extension** before your current return time.

![](/guides/img/renter-11-extend-desktop-957274cc.jpg "desktop; size: 960 552; address: carmacars.ca/account/bookings/CC-10057/extend; pins: 2 34.4 62.9, 3 15.1 77.2")

> Watch out: Ask before your current return time. One rental can be at most 30 days.

## Ask to change dates

1. On your booking, press **Ask to change dates**.
2. Set the new pickup and return, then press **See the difference** to see what you would pay or get back.
3. Press **Ask to change dates** to send it. Nothing changes until you agree to our answer.

![](/guides/img/renter-12-change-desktop-09f6b563.jpg "desktop; size: 960 552; address: carmacars.ca/account/bookings/CC-10057/change; pins: 2 15.1 91.8")

## A change we suggest

Sometimes we need to change your booking, for example another car of the same class. You decide.

1. You get an email, and your booking says "We suggest a change to your booking". Press **Review and answer**.
2. Read what changes (before and after), the reason, the money and the time left to answer.
3. To agree, press **Accept and sign the amendment**, sign, then press **Accept and sign**.
4. Anything more to pay is charged to your Card on File. If the card is declined, press **Pay and apply the change**.
5. To say no, press **Decline this change**. Your booking stays as it was.

> Tip: You have 48 hours to answer, and we send one reminder. CarmaCars signs the amendment at the moment you sign it, and the signed copy is saved under Documents. If the change costs less, the refund goes back to your card within 10 business days after the amendment is signed.

## Cancel a booking

1. On your booking, press **Cancel booking**.
2. Read What you get back. It shows the rule that applies and your refund.
3. Type the booking number to confirm (for example CC-10021), then press **Cancel booking**.

![](/guides/img/renter-13-cancel-desktop-d0bb2c67.jpg "desktop; size: 1440 692; address: carmacars.ca/account/bookings/CC-10057/cancel; pins: 2 36.1 67.2, 3 95.8 45.1")

| Standard booking: when you cancel | Refund of what you paid |
| --- | --- |
| Within 24 hours of booking, and 48 hours or more before pickup | 95% back |
| 48 hours or more before pickup | 75% back |
| 24 to 48 hours before pickup | 50% back |
| Less than 24 hours before pickup | No refund |

A Non-refundable booking gets no refund. The deposit is taken at pickup, so none is held when you cancel before it.

## Messages, tolls and tickets

- Write to us about a booking at the bottom of its page: type in Your message and press Send.
- Tolls and tickets are yours to pay, including Highway 407 ETR. If one reaches us, we pay it and charge the amount plus our fee to your Card on File, and email you a copy of the notice.
- Running late? Ask to extend before your return time, or call us at 647-575-3377.
',
  '<p class="gd-p">Plans change. You can ask for more days, ask to change dates, answer a change we suggest, or cancel, all from your booking.</p><section class="gd-task" id="during-your-trip-extend-your-rental" data-gd-task><h2 class="gd-h2">Extend your rental</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On your booking, press <b class="gd-ui">Extend</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the new return date and time, then press <b class="gd-ui">See the price</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Request extension</b>. Once we approve it, press <b class="gd-ui">Pay for the extension</b> before your current return time.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10057/extend</span></div><div class="gd-imgwrap" style="aspect-ratio:960/552"><img src="/guides/img/renter-11-extend-desktop-957274cc.jpg" alt="" loading="lazy" decoding="async" width="960" height="552"><span class="gd-pin" style="left:34.4%;top:62.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:15.1%;top:77.2%" aria-hidden="true">3</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Ask before your current return time. One rental can be at most 30 days.</div></aside></section><section class="gd-task" id="during-your-trip-ask-to-change-dates" data-gd-task><h2 class="gd-h2">Ask to change dates</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On your booking, press <b class="gd-ui">Ask to change dates</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Set the new pickup and return, then press <b class="gd-ui">See the difference</b> to see what you would pay or get back.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Ask to change dates</b> to send it. Nothing changes until you agree to our answer.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10057/change</span></div><div class="gd-imgwrap" style="aspect-ratio:960/552"><img src="/guides/img/renter-12-change-desktop-09f6b563.jpg" alt="" loading="lazy" decoding="async" width="960" height="552"><span class="gd-pin" style="left:15.1%;top:91.8%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="during-your-trip-a-change-we-suggest" data-gd-task><h2 class="gd-h2">A change we suggest</h2><p class="gd-p">Sometimes we need to change your booking, for example another car of the same class. You decide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">You get an email, and your booking says &quot;We suggest a change to your booking&quot;. Press <b class="gd-ui">Review and answer</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Read what changes (before and after), the reason, the money and the time left to answer.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To agree, press <b class="gd-ui">Accept and sign the amendment</b>, sign, then press <b class="gd-ui">Accept and sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Anything more to pay is charged to your Card on File. If the card is declined, press <b class="gd-ui">Pay and apply the change</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">To say no, press <b class="gd-ui">Decline this change</b>. Your booking stays as it was.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>You have 48 hours to answer, and we send one reminder. CarmaCars signs the amendment at the moment you sign it, and the signed copy is saved under Documents. If the change costs less, the refund goes back to your card within 10 business days after the amendment is signed.</div></aside></section><section class="gd-task" id="during-your-trip-cancel-a-booking" data-gd-task><h2 class="gd-h2">Cancel a booking</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On your booking, press <b class="gd-ui">Cancel booking</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Read What you get back. It shows the rule that applies and your refund.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Type the booking number to confirm (for example CC-10021), then press <b class="gd-ui">Cancel booking</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10057/cancel</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/692"><img src="/guides/img/renter-13-cancel-desktop-d0bb2c67.jpg" alt="" loading="lazy" decoding="async" width="1440" height="692"><span class="gd-pin" style="left:36.1%;top:67.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:95.8%;top:45.1%" aria-hidden="true">3</span></div></div></figure></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Standard booking: when you cancel</th><th scope="col">Refund of what you paid</th></tr></thead><tbody><tr><td>Within 24 hours of booking, and 48 hours or more before pickup</td><td>95% back</td></tr><tr><td>48 hours or more before pickup</td><td>75% back</td></tr><tr><td>24 to 48 hours before pickup</td><td>50% back</td></tr><tr><td>Less than 24 hours before pickup</td><td>No refund</td></tr></tbody></table></div><p class="gd-p">A Non-refundable booking gets no refund. The deposit is taken at pickup, so none is held when you cancel before it.</p></section><section class="gd-task" id="during-your-trip-messages-tolls-and-tickets" data-gd-task><h2 class="gd-h2">Messages, tolls and tickets</h2><ul class="gd-ul"><li>Write to us about a booking at the bottom of its page: type in Your message and press Send.</li><li>Tolls and tickets are yours to pay, including Highway 407 ETR. If one reaches us, we pay it and charge the amount plus our fee to your Card on File, and email you a copy of the notice.</li><li>Running late? Ask to extend before your return time, or call us at 647-575-3377.</li></ul></section>');
select app.guide_release_section('renter', 'after-your-trip', 'chapter', 'during-your-trip', 'We check the car with you at the return. Your deposit balance comes back, and your receipts and agreement stay in your portal.

## The return and your deposit

- At the return we check the odometer, fuel or charge, keys and cleanliness, take photos and compare with pickup. You sign on our screen.
- We release the deposit balance after you return the car. If a toll, ticket or claim is still open, we may hold back what we expect it to cost for a while.
- Your statement appears under Documents.

## Review your rental

1. Open the trip under Past, then press **Review your rental**.
2. Tap the stars. Add a title and a few words if you like. Both are optional.
3. Tick **Show my review on the site with my first name** only if you agree to it being shown.
4. Press **Send my review**.

![](/guides/img/renter-14-review-desktop-c6c61830.jpg "desktop; size: 1440 672; address: carmacars.ca/account/bookings/CC-10022/review; pins: 2 25.0 33.6, 3 3.5 84.5, 4 18.1 92.4")

## Documents, notifications and profile

1. **Documents**: your agreements, receipts, statements and uploads. Press **View** or **Download**.
2. **Notifications**: notices from us. Use **Mark as read** or **Mark all as read**, and choose which optional emails you get.
3. **Profile**: your contact details (**Save**), drivers, your Card on File and your marketing choice.

![](/guides/img/renter-15-documents-desktop-fd428a63.jpg "desktop; size: 1440 560; address: carmacars.ca/account/documents; pins: 1 91.8 35.7")

> Tip: Your legal name is locked once you are verified. To change it or your email, call or message us.
', 'After your trip', 'The return, your deposit, reviews, documents and your profile.',
  'We check the car with you at the return. Your deposit balance comes back, and your receipts and agreement stay in your portal.

## The return and your deposit

- At the return we check the odometer, fuel or charge, keys and cleanliness, take photos and compare with pickup. You sign on our screen.
- We release the deposit balance after you return the car. If a toll, ticket or claim is still open, we may hold back what we expect it to cost for a while.
- Your statement appears under Documents.

## Review your rental

1. Open the trip under Past, then press **Review your rental**.
2. Tap the stars. Add a title and a few words if you like. Both are optional.
3. Tick **Show my review on the site with my first name** only if you agree to it being shown.
4. Press **Send my review**.

![](/guides/img/renter-14-review-desktop-c6c61830.jpg "desktop; size: 1440 672; address: carmacars.ca/account/bookings/CC-10058/review; pins: 2 25.0 33.6, 3 3.5 84.5, 4 18.1 92.4")

## Documents, notifications and profile

1. **Documents**: your agreements, receipts, statements and uploads. Press **View** or **Download**.
2. **Notifications**: notices from us. Use **Mark as read** or **Mark all as read**, and choose which optional emails you get.
3. **Profile**: your contact details (**Save**), drivers, your Card on File and your marketing choice.

![](/guides/img/renter-15-documents-desktop-fd428a63.jpg "desktop; size: 1440 560; address: carmacars.ca/account/documents; pins: 1 91.8 35.7")

> Tip: Your legal name is locked once you are verified. To change it or your email, call or message us.
',
  '<p class="gd-p">We check the car with you at the return. Your deposit balance comes back, and your receipts and agreement stay in your portal.</p><section class="gd-task" id="after-your-trip-the-return-and-your-deposit" data-gd-task><h2 class="gd-h2">The return and your deposit</h2><ul class="gd-ul"><li>At the return we check the odometer, fuel or charge, keys and cleanliness, take photos and compare with pickup. You sign on our screen.</li><li>We release the deposit balance after you return the car. If a toll, ticket or claim is still open, we may hold back what we expect it to cost for a while.</li><li>Your statement appears under Documents.</li></ul></section><section class="gd-task" id="after-your-trip-review-your-rental" data-gd-task><h2 class="gd-h2">Review your rental</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the trip under Past, then press <b class="gd-ui">Review your rental</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Tap the stars. Add a title and a few words if you like. Both are optional.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Tick <b class="gd-ui">Show my review on the site with my first name</b> only if you agree to it being shown.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Send my review</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/bookings/CC-10058/review</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/672"><img src="/guides/img/renter-14-review-desktop-c6c61830.jpg" alt="" loading="lazy" decoding="async" width="1440" height="672"><span class="gd-pin" style="left:25%;top:33.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:3.5%;top:84.5%" aria-hidden="true">3</span><span class="gd-pin" style="left:18.1%;top:92.4%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="after-your-trip-documents-notifications-and-profile" data-gd-task><h2 class="gd-h2">Documents, notifications and profile</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Documents</b>: your agreements, receipts, statements and uploads. Press <b class="gd-ui">View</b> or <b class="gd-ui">Download</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Notifications</b>: notices from us. Use <b class="gd-ui">Mark as read</b> or <b class="gd-ui">Mark all as read</b>, and choose which optional emails you get.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Profile</b>: your contact details (<b class="gd-ui">Save</b>), drivers, your Card on File and your marketing choice.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/account/documents</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/560"><img src="/guides/img/renter-15-documents-desktop-fd428a63.jpg" alt="" loading="lazy" decoding="async" width="1440" height="560"><span class="gd-pin" style="left:91.8%;top:35.7%" aria-hidden="true">1</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Your legal name is locked once you are verified. To change it or your email, call or message us.</div></aside></section>');
select app.guide_release_section('renter', 'quick-reference', 'reference', 'after-your-trip', '### Where things are

| Item | What it is for |
| --- | --- |
| **Trips** | Your next step first, then current, upcoming and past trips |
| **Documents** | Agreements, receipts, statements, uploads |
| **Notifications** | Notices and your email choices |
| **Profile** | Contact details, drivers, Card on File |

### Top tasks

1. **Request a car** ›*a car›*Request to book
2. **Approve an offer** ›*Review offer›*Approve and continue
3. **Sign and pay** **All four**, **Sign and continue to payment**, then **Pay $...**
4. **Upload documents** ›*Licence and coverage
5. **Extend or change dates** **Extend** or **Ask to change dates**
6. **Answer a change we suggest** **Review and answer**
7. **Cancel** ›*Cancel booking
8. **Review your trip** **Review your rental**

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **"This car was just taken"** | Someone confirmed first. Your card is released; pick from the car or dates we offer. |
| **No confirmation email** | Check spam, then use **Send the confirmation link again** on the sign-in form. |
', 'Quick reference', 'One page with the essentials.',
  '### Where things are

| Item | What it is for |
| --- | --- |
| **Trips** | Your next step first, then current, upcoming and past trips |
| **Documents** | Agreements, receipts, statements, uploads |
| **Notifications** | Notices and your email choices |
| **Profile** | Contact details, drivers, Card on File |

### Top tasks

1. *Request a car:* **Find a car**, the car, then **Request to book**
2. *Approve an offer:* **Trips** > **Review offer** > **Approve and continue**
3. *Sign and pay:* **All four**, **Sign and continue to payment**, then **Pay $...**
4. *Upload documents:* **Your booking** > **Licence and coverage**
5. *Extend or change dates:* **Extend** or **Ask to change dates**
6. *Answer a change we suggest:* **Review and answer**
7. *Cancel:* **Your booking** > **Cancel booking**
8. *Review your trip:* **Review your rental**

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **"This car was just taken"** | Someone confirmed first. Your card is released; pick from the car or dates we offer. |
| **No confirmation email** | Check spam, then use **Send the confirmation link again** on the sign-in form. |
',
  '<h3 class="gd-h3">Where things are</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Item</th><th scope="col">What it is for</th></tr></thead><tbody><tr><td><b class="gd-ui">Trips</b></td><td>Your next step first, then current, upcoming and past trips</td></tr><tr><td><b class="gd-ui">Documents</b></td><td>Agreements, receipts, statements, uploads</td></tr><tr><td><b class="gd-ui">Notifications</b></td><td>Notices and your email choices</td></tr><tr><td><b class="gd-ui">Profile</b></td><td>Contact details, drivers, Card on File</td></tr></tbody></table></div><h3 class="gd-h3">Top tasks</h3><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><em>Request a car:</em> <b class="gd-ui">Find a car</b>, the car, then <b class="gd-ui">Request to book</b></div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><em>Approve an offer:</em> <b class="gd-ui">Trips</b> &gt; <b class="gd-ui">Review offer</b> &gt; <b class="gd-ui">Approve and continue</b></div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><em>Sign and pay:</em> <b class="gd-ui">All four</b>, <b class="gd-ui">Sign and continue to payment</b>, then <b class="gd-ui">Pay $...</b></div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><em>Upload documents:</em> <b class="gd-ui">Your booking</b> &gt; <b class="gd-ui">Licence and coverage</b></div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><em>Extend or change dates:</em> <b class="gd-ui">Extend</b> or <b class="gd-ui">Ask to change dates</b></div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><em>Answer a change we suggest:</em> <b class="gd-ui">Review and answer</b></div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><em>Cancel:</em> <b class="gd-ui">Your booking</b> &gt; <b class="gd-ui">Cancel booking</b></div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t"><em>Review your trip:</em> <b class="gd-ui">Review your rental</b></div></li></ol></div><h3 class="gd-h3">If something goes wrong</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">What you see</th><th scope="col">What to do</th></tr></thead><tbody><tr><td><b class="gd-ui">A link says it expired</b></td><td>Links in our emails work for 24 hours, once. Press <b class="gd-ui">Send me a new link</b> on that page.</td></tr><tr><td><b class="gd-ui">&quot;Error 1102&quot; on a page</b></td><td>A short limit on our web host. Reload the page. You are still signed in.</td></tr><tr><td><b class="gd-ui">&quot;That email and password do not match an account.&quot;</b></td><td>Check the address, or use <b class="gd-ui">Set a new password</b> on the sign-in page.</td></tr><tr><td><b class="gd-ui">&quot;This car was just taken&quot;</b></td><td>Someone confirmed first. Your card is released; pick from the car or dates we offer.</td></tr><tr><td><b class="gd-ui">No confirmation email</b></td><td>Check spam, then use <b class="gd-ui">Send the confirmation link again</b> on the sign-in form.</td></tr></tbody></table></div>');
select app.guide_release_section('owner', 'apply-and-get-your-car-listed', 'chapter', 'start-here', 'You apply online in about ten minutes. We reply within one business day, set your terms, and walk you through the rest.

## Apply to list your car

1. Go to `carmacars.ca/list-your-car` and press **Apply to list your car**.
2. About you: individual or corporation, your address, licence and date of birth. Press **Continue to vehicles**.
3. For each car, type the VIN and press **Look up**. Use **Add another vehicle** for more cars.
4. Read how it will work, press **Continue**, then **Review**.
5. Press **Submit application**, then **Go to your owner portal**.

![](/guides/img/public-13-list-your-car-desktop-48bf4cb0.jpg "desktop; size: 1440 800; address: carmacars.ca/list-your-car; pins: 1 20.1 74.9")

> Tip: Need a break? **Email me a link** saves your application and sends you a link to finish later.

## What happens next

Five steps take your car from your driveway to its first rental.

:::flow
Tell us about the car | We confirm fees and set your terms
Sign the agreements | Online, one for all your cars
One registry visit | We fill in the forms and come with you
Tracker and insurance | We install it and add the car
Photos and listing | Live within 1 business day
:::

1. When your terms are ready, Home shows **Check and sign**. Everything is filled in from your application: check the short list of key values (each has a **Fix** link) and open any document to read it in full.
2. Tap **All of these** for the three confirmations (your initials are filled in), then press **Sign all**. Your name on file is your signature; prefer to draw it? Press **Draw instead**. One signature covers every document, in about a minute.
3. Pay the upfront invoice: the first and last month''s insurance fee for each car (see chapter 4).
4. Upload what each car''s checklist asks for: the ownership permit, the lender''s permission if it is financed or leased, and insurance.
5. Print Forms C and D (filled in for you), sign them in front of witnesses and take a photo of each page with your phone (see chapter 5).
', 'Apply and get your car listed', 'Apply online, sign, pay the upfront invoice and get your car on the site.',
  'You apply online in about ten minutes. We reply within one business day, set your terms, and walk you through the rest.

## Apply to list your car

1. Go to `carmacars.ca/list-your-car` and press **Apply to list your car**.
2. About you: individual or corporation, your address, licence and date of birth. Press **Continue to vehicles**.
3. For each car, type the VIN and press **Look up**. Use **Add another vehicle** for more cars.
4. Read how it will work, press **Continue**, then **Review**.
5. Press **Submit application**, then **Go to your owner portal**.

![](/guides/img/public-13-list-your-car-desktop-48bf4cb0.jpg "desktop; size: 1440 800; address: carmacars.ca/list-your-car; pins: 1 20.1 74.9")

> Tip: Need a break? **Email me a link** saves your application and sends you a link to finish later.

## What happens next

Five steps take your car from your driveway to its first rental.

:::flow
Tell us about the car | We confirm fees and set your terms
Sign the agreements | Online, one for all your cars
One registry visit | We fill in the forms and come with you
Tracker and insurance | We install it and add the car
Photos and listing | Live within 1 business day
:::

1. When your terms are ready, Home shows **Check and sign**. Everything is filled in from your application: check the short list of key values (each has a **Fix** link) and open any document to read it in full.
2. Tap **All of these** for the three confirmations (your initials are filled in), then press **Sign all**. Your name on file is your signature; prefer to draw it? Press **Draw instead**. One signature covers every document, in about a minute.
3. Pay the upfront invoice: the first and last month''s insurance fee for each car (see chapter 4).
4. Upload what each car''s checklist asks for: the ownership permit, the lender''s permission if it is financed or leased, and insurance.
5. Sign Forms C and D (filled in for you) with witnesses: Form C on screen with your witness beside you, or on paper; Form D on paper, with a photo of each page from your phone (see chapter 5).

## If we need a little more

Sometimes we need one more document before we can approve your application, for example the ownership permit or the insurance slip.

1. You get an email, and Home shows "We need a little more" with the list and any note from our team.
2. Upload what is asked, or write Your answer, and press **Send my answer**.
3. We review it within 1 business day. Once we approve your application, you get an email and Home shows Check and sign.
',
  '<p class="gd-p">You apply online in about ten minutes. We reply within one business day, set your terms, and walk you through the rest.</p><section class="gd-task" id="apply-and-get-your-car-listed-apply-to-list-your-car" data-gd-task><h2 class="gd-h2">Apply to list your car</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Go to <span class="gd-url">carmacars.ca/list-your-car</span> and press <b class="gd-ui">Apply to list your car</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">About you: individual or corporation, your address, licence and date of birth. Press <b class="gd-ui">Continue to vehicles</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">For each car, type the VIN and press <b class="gd-ui">Look up</b>. Use <b class="gd-ui">Add another vehicle</b> for more cars.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Read how it will work, press <b class="gd-ui">Continue</b>, then <b class="gd-ui">Review</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Submit application</b>, then <b class="gd-ui">Go to your owner portal</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/list-your-car</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/800"><img src="/guides/img/public-13-list-your-car-desktop-48bf4cb0.jpg" alt="" loading="lazy" decoding="async" width="1440" height="800"><span class="gd-pin" style="left:20.1%;top:74.9%" aria-hidden="true">1</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Need a break? <b class="gd-ui">Email me a link</b> saves your application and sends you a link to finish later.</div></aside></section><section class="gd-task" id="apply-and-get-your-car-listed-what-happens-next" data-gd-task><h2 class="gd-h2">What happens next</h2><p class="gd-p">Five steps take your car from your driveway to its first rental.</p><ol class="gd-flow"><li><b>1</b><span>Tell us about the car</span><em>We confirm fees and set your terms</em></li><li><b>2</b><span>Sign the agreements</span><em>Online, one for all your cars</em></li><li><b>3</b><span>One registry visit</span><em>We fill in the forms and come with you</em></li><li><b>4</b><span>Tracker and insurance</span><em>We install it and add the car</em></li><li><b>5</b><span>Photos and listing</span><em>Live within 1 business day</em></li></ol><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When your terms are ready, Home shows <b class="gd-ui">Check and sign</b>. Everything is filled in from your application: check the short list of key values (each has a <b class="gd-ui">Fix</b> link) and open any document to read it in full.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Tap <b class="gd-ui">All of these</b> for the three confirmations (your initials are filled in), then press <b class="gd-ui">Sign all</b>. Your name on file is your signature; prefer to draw it? Press <b class="gd-ui">Draw instead</b>. One signature covers every document, in about a minute.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Pay the upfront invoice: the first and last month&#39;s insurance fee for each car (see chapter 4).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Upload what each car&#39;s checklist asks for: the ownership permit, the lender&#39;s permission if it is financed or leased, and insurance.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Sign Forms C and D (filled in for you) with witnesses: Form C on screen with your witness beside you, or on paper; Form D on paper, with a photo of each page from your phone (see chapter 5).</div></li></ol></div></section><section class="gd-task" id="apply-and-get-your-car-listed-if-we-need-a-little-more" data-gd-task><h2 class="gd-h2">If we need a little more</h2><p class="gd-p">Sometimes we need one more document before we can approve your application, for example the ownership permit or the insurance slip.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">You get an email, and Home shows &quot;We need a little more&quot; with the list and any note from our team.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Upload what is asked, or write Your answer, and press <b class="gd-ui">Send my answer</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">We review it within 1 business day. Once we approve your application, you get an email and Home shows Check and sign.</div></li></ol></div></section>');
select app.guide_release_section('owner', 'home-and-your-vehicles', 'chapter', 'apply-and-get-your-car-listed', 'Home tells you what to do next. Each car has its own page with its status, terms, bookings, invoices and photos.

## Home at a glance

1. The menu: Home, Vehicles, Bookings, Invoices, Statements, Payouts, Documents, Banking, Notifications and Profile.
2. Your vehicles: each car with its status and what it needs next.
3. Money: what is due now, your fees each month, the next billing date and the next payout date.
4. Got another car? Press **Add a vehicle**.

![](/guides/img/owner-01-home-desktop-841aa611.jpg "desktop; size: 1440 760; address: carmacars.ca/owner; pins: 1 32.6 22.9, 2 42.7 52.6, 3 74.7 50.0, 4 38.9 46.1")

> Tip: When something needs you (a signature, a payment or an upload), it is the first thing on Home.

## A car''s page

Open Vehicles, then a car.

1. The top shows the car, its plate and how it is enrolled, with its status.
2. Terms: the Insurance Fee, the Revenue Share, your enrolment date and a link to the listing.
3. Bookings shows every trip in your car. **Book it for myself** reserves it for you.
4. Leaving explains the exit notice and has the button to give it.

![](/guides/img/owner-03-vehicle-desktop-fc3e7e98.jpg "desktop; size: 1440 1292; address: carmacars.ca/owner/vehicles/e6258c8d-17af-427d-a5e6-8828343a416d; pins: 1 47.9 14.9, 2 73.4 24.6, 3 23.3 76.4, 4 81.9 64.6")

While a car is being set up, its page also shows the onboarding checklist and the uploads it still needs: the ownership permit, the lender''s permission and the insurance.

## Take new listing photos

Good photos get more bookings. You can shoot them yourself with your phone.

1. On the car''s page, press **Add listing photos** (or **Take new photos** for a car already live).
2. Read the tips for each shot: daylight, a plain background, the phone held landscape.
3. Press **Take photo** for each shot in the list. Press **Retake** if one is not right.
4. The bar shows how many required photos you have.
5. Press **Submit for listing**. New photos replace the current ones once our team approves them.

![](/guides/img/field-06-photo-shoot-capture-phone-d0b13740.jpg "phone; size: 390 610; pins: 4 92.3 43.4, 3 76.9 70.2")
', 'Home and your vehicles', 'What Home shows, each car''s page, adding a car and new listing photos.',
  'Home tells you what to do next. Each car has its own page with its status, terms, bookings, invoices and photos.

## Home at a glance

1. The menu: Home, Vehicles, Bookings, Invoices, Statements, Payouts, Documents, Banking, Notifications and Profile.
2. Your vehicles: each car with its status and what it needs next.
3. Money: what is due now, your fees each month, the next billing date and the next payout date.
4. Got another car? Press **Add a vehicle**.

![](/guides/img/owner-01-home-desktop-841aa611.jpg "desktop; size: 1440 760; address: carmacars.ca/owner; pins: 1 32.6 22.9, 2 42.7 52.6, 3 74.7 50.0, 4 38.9 46.1")

> Tip: When something needs you (a signature, a payment or an upload), it is the first thing on Home.

## A car''s page

Open Vehicles, then a car.

1. The top shows the car, its plate and how it is enrolled, with its status.
2. Terms: the Insurance Fee, the Revenue Share, your enrolment date and a link to the listing.
3. Bookings shows every trip in your car. **Book it for myself** reserves it for you.
4. Leaving explains the exit notice and has the button to give it.

![](/guides/img/owner-03-vehicle-desktop-fc3e7e98.jpg "desktop; size: 1440 1292; address: carmacars.ca/owner/vehicles/aece3b1c-489e-4ad0-a2f0-c34415506c58; pins: 1 47.9 14.9, 2 73.4 24.6, 3 23.3 76.4, 4 81.9 64.6")

While a car is being set up, its page also shows the onboarding checklist and the uploads it still needs: the ownership permit, the lender''s permission and the insurance.

## Take new listing photos

Good photos get more bookings. You can shoot them yourself with your phone.

1. On the car''s page, press **Add listing photos** (or **Take new photos** for a car already live).
2. Read the tips for each shot: daylight, a plain background, the phone held landscape.
3. Press **Take photo** for each shot in the list. Press **Retake** if one is not right.
4. The bar shows how many required photos you have.
5. Press **Submit for listing**. New photos replace the current ones once our team approves them.

![](/guides/img/field-06-photo-shoot-capture-phone-d0b13740.jpg "phone; size: 390 610; pins: 4 92.3 43.4, 3 76.9 70.2")
',
  '<p class="gd-p">Home tells you what to do next. Each car has its own page with its status, terms, bookings, invoices and photos.</p><section class="gd-task" id="home-and-your-vehicles-home-at-a-glance" data-gd-task><h2 class="gd-h2">Home at a glance</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The menu: Home, Vehicles, Bookings, Invoices, Statements, Payouts, Documents, Banking, Notifications and Profile.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Your vehicles: each car with its status and what it needs next.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Money: what is due now, your fees each month, the next billing date and the next payout date.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Got another car? Press <b class="gd-ui">Add a vehicle</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/760"><img src="/guides/img/owner-01-home-desktop-841aa611.jpg" alt="" loading="lazy" decoding="async" width="1440" height="760"><span class="gd-pin" style="left:32.6%;top:22.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:42.7%;top:52.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:74.7%;top:50%" aria-hidden="true">3</span><span class="gd-pin" style="left:38.9%;top:46.1%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>When something needs you (a signature, a payment or an upload), it is the first thing on Home.</div></aside></section><section class="gd-task" id="home-and-your-vehicles-a-car-s-page" data-gd-task><h2 class="gd-h2">A car&#39;s page</h2><p class="gd-p">Open Vehicles, then a car.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The top shows the car, its plate and how it is enrolled, with its status.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Terms: the Insurance Fee, the Revenue Share, your enrolment date and a link to the listing.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Bookings shows every trip in your car. <b class="gd-ui">Book it for myself</b> reserves it for you.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Leaving explains the exit notice and has the button to give it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/vehicles/aece3b1c-489e-4ad0-a2f0-c34415506c58</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1292"><img src="/guides/img/owner-03-vehicle-desktop-fc3e7e98.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1292"><span class="gd-pin" style="left:47.9%;top:14.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:73.4%;top:24.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:23.3%;top:76.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:81.9%;top:64.6%" aria-hidden="true">4</span></div></div></figure></div><p class="gd-p">While a car is being set up, its page also shows the onboarding checklist and the uploads it still needs: the ownership permit, the lender&#39;s permission and the insurance.</p></section><section class="gd-task" id="home-and-your-vehicles-take-new-listing-photos" data-gd-task><h2 class="gd-h2">Take new listing photos</h2><p class="gd-p">Good photos get more bookings. You can shoot them yourself with your phone.</p><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the car&#39;s page, press <b class="gd-ui">Add listing photos</b> (or <b class="gd-ui">Take new photos</b> for a car already live).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Read the tips for each shot: daylight, a plain background, the phone held landscape.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Take photo</b> for each shot in the list. Press <b class="gd-ui">Retake</b> if one is not right.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The bar shows how many required photos you have.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Submit for listing</b>. New photos replace the current ones once our team approves them.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/610"><img src="/guides/img/field-06-photo-shoot-capture-phone-d0b13740.jpg" alt="" loading="lazy" decoding="async" width="390" height="610"><span class="gd-pin" style="left:92.3%;top:43.4%" aria-hidden="true">4</span><span class="gd-pin" style="left:76.9%;top:70.2%" aria-hidden="true">3</span></div></div></figure></div></section>');
select app.guide_release_section('owner', 'fees-payments-and-payouts', 'chapter', 'bookings-and-your-own-use', 'Your fees are debited from your bank account on the 15th, after a notice. Your payout for the month before arrives on the 10th, with a statement.

## How your fees work

- Each car has two monthly fees: an insurance fee and a tracker fee. They are due every month, rented or not.
- The tracker fee starts the day the car''s tracker is installed. The tracker install fee has its own invoice.
- Before a car goes live you pay the upfront invoice: the first and last month''s insurance fee.
- One invoice per car. Registry, inspection and appraisal costs are not billed by us; you pay them directly.

## The monthly debit, step by step

:::flow
Notice day | 10 days before: your invoices and one email with the total
The 15th | Each invoice is debited from your account
Cleared | The invoice shows Paid and you get a receipt
Returned? | A $50 Late Fee once, then a retry from the 18th
:::

- A debit is never more than its notice said. Each invoice shows "will be debited on" with the date.
- After two returned debits the invoice is in arrears and we contact you.
- You can always pay an invoice by card from its page before the debit day.

## Set up the automatic debit

Do this once. Without it, we email you on each notice day to set it up.

1. Open **Banking**. Under Automatic debit of your fees, press **Set up pre-authorized debit**.
2. Read the agreement and press **Continue to my bank details**.
3. Enter your bank details and press **Save the bank account**. Banking then shows the account and the next debit.

![](/guides/img/owner-07-banking-desktop-52316739.jpg "desktop; size: 1440 752; address: carmacars.ca/owner/banking; pins: 1 96.2 36.8")

## Pay an invoice now

1. Open Invoices, then the invoice. It lists what it covers and the balance.
2. Choose Card (paid at once) and press **Pay $...**.
3. Or choose Pre-authorized debit (from a Canadian bank account, clears in 3 to 5 business days) and press **Authorize debit of $...**.
4. Prefer Interac e-Transfer? Send the amount to billing@carmacars.ca with the invoice number in the message.

![](/guides/img/owner-06-invoice-desktop-bba2c020.jpg "desktop; size: 1440 742; address: carmacars.ca/owner/invoices/INV-1006; pins: 2 6.9 52.6, 3 38.2 52.6, 4 11.5 80.5")

> Tip: Paid us by e-Transfer, cheque, cash or bank transfer? Once we record it, the invoice says "Paid by e-Transfer on" the date, you get a receipt by email, and the automatic debit does not take that amount. Paid part of it? The invoice shows Partly paid and only the rest is debited.

## Tell us where to pay you

1. Open **Banking**. Under Where we pay you, choose Bank transfer or e-Transfer.
2. Fill in Account holder, Institution number, Transit number and Account number (or your e-Transfer email).
3. Press **Submit payout details**. For your security we confirm new details by phone before we use them.

![](/guides/img/owner-07-banking-desktop-87b2ffe3.jpg "desktop; size: 990 642; address: carmacars.ca/owner/banking; pins: 1 50.5 25.7, 2 90.9 45.5, 3 30.3 89.7")

## Statements and payouts

1. Statements: one a month, once approved by CarmaCars. Open one to see every booking, the revenue share, deductions and the payout.
2. Press **Download PDF** to keep a copy. We also email it to you with the PDF attached.
3. Payouts shows what was paid to you and when. Payouts are made on the 10th for the month before.

![](/guides/img/owner-09-statement-desktop-fc5f9ea5.jpg "desktop; size: 1440 792; address: carmacars.ca/owner/statements/4737267c-0d29-4e43-98f4-ad6d48ca9356; pins: 2 16.0 30.6, 1 66.0 40.9")
', 'Fees, payments and payouts', 'How fees are billed, the monthly debit, paying an invoice, statements and payouts.',
  'Your fees are debited from your bank account on the 15th, after a notice. Your payout for the month before arrives on the 10th, with a statement.

## How your fees work

- Each car has two monthly fees: an insurance fee and a tracker fee. They are due every month, rented or not.
- The tracker fee starts the day the car''s tracker is installed. The tracker install fee has its own invoice.
- Before a car goes live you pay the upfront invoice: the first and last month''s insurance fee.
- One invoice per car. Registry, inspection and appraisal costs are not billed by us; you pay them directly.

## The monthly debit, step by step

:::flow
Notice day | 10 days before: your invoices and one email with the total
The 15th | Each invoice is debited from your account
Cleared | The invoice shows Paid and you get a receipt
Insufficient funds? | A $50.00 Late Fee once, and the same amount tried again within 30 days
:::

- A debit is never more than its notice said. Each invoice shows "will be debited on" with the date.
- If your bank returns a debit for insufficient funds, we add the $50.00 Late Fee to that invoice once and try the original amount again within 30 days, as section 4.4 of your Enrollment Agreement sets out. The Late Fee is collected with your next debit.
- Returned for another reason (for example a closed account)? We do not try again and add no Late Fee. We pause your debit and email you: pay the invoice from its page, or set up a new account under Banking.
- Returned again after the retry? The invoice is in arrears and we contact you.
- You can always pay an invoice by card from its page before the debit day.
- On your bank statement the debit shows our company''s legal name, operating as CarmaCars.

## Set up the automatic debit

Do this once. Without it, we email you on each notice day to set it up.

1. Open **Banking**. Under Automatic debit of your fees, press **Set up pre-authorized debit**.
2. Read the agreement and press **Continue to my bank details**.
3. Enter your bank details and press **Save the bank account**. Banking then shows the account and the next debit.

![](/guides/img/owner-07-banking-desktop-52316739.jpg "desktop; size: 1440 752; address: carmacars.ca/owner/banking; pins: 1 96.2 36.8")

## Pay an invoice now

1. Open Invoices, then the invoice. It lists what it covers and the balance.
2. Choose Card (paid at once) and press **Pay $...**.
3. Or choose Pre-authorized debit (from a Canadian bank account, clears in 3 to 5 business days) and press **Authorize debit of $...**.
4. Prefer Interac e-Transfer? Send the amount to billing@carmacars.ca with the invoice number in the message.

![](/guides/img/owner-06-invoice-desktop-bba2c020.jpg "desktop; size: 1440 742; address: carmacars.ca/owner/invoices/INV-1050; pins: 2 6.9 52.6, 3 38.2 52.6, 4 11.5 80.5")

> Tip: Paid us by e-Transfer, cheque, cash or bank transfer? Once we record it, the invoice says "Paid by e-Transfer on" the date, you get a receipt by email, and the automatic debit does not take that amount. Paid part of it? The invoice shows Partly paid and only the rest is debited.

## Tell us where to pay you

1. Open **Banking**. Under Where we pay you, choose Bank transfer or e-Transfer.
2. Fill in Account holder, Institution number, Transit number and Account number (or your e-Transfer email).
3. Press **Submit payout details**. For your security we confirm new details by phone before we use them.

![](/guides/img/owner-07-banking-desktop-87b2ffe3.jpg "desktop; size: 990 642; address: carmacars.ca/owner/banking; pins: 1 50.5 25.7, 2 90.9 45.5, 3 30.3 89.7")

## Statements and payouts

1. Statements: one a month, once approved by CarmaCars. Open one to see every booking, the revenue share, deductions and the payout.
2. Press **Download PDF** to keep a copy. We also email it to you with the PDF attached.
3. Payouts shows what was paid to you and when. Payouts are made on the 10th for the month before.

![](/guides/img/owner-09-statement-desktop-fc5f9ea5.jpg "desktop; size: 1440 792; address: carmacars.ca/owner/statements/f27936a8-9bfb-4280-81ae-c67ec47febe1; pins: 2 16.0 30.6, 1 66.0 40.9")
',
  '<p class="gd-p">Your fees are debited from your bank account on the 15th, after a notice. Your payout for the month before arrives on the 10th, with a statement.</p><section class="gd-task" id="fees-payments-and-payouts-how-your-fees-work" data-gd-task><h2 class="gd-h2">How your fees work</h2><ul class="gd-ul"><li>Each car has two monthly fees: an insurance fee and a tracker fee. They are due every month, rented or not.</li><li>The tracker fee starts the day the car&#39;s tracker is installed. The tracker install fee has its own invoice.</li><li>Before a car goes live you pay the upfront invoice: the first and last month&#39;s insurance fee.</li><li>One invoice per car. Registry, inspection and appraisal costs are not billed by us; you pay them directly.</li></ul></section><section class="gd-task" id="fees-payments-and-payouts-the-monthly-debit-step-by-step" data-gd-task><h2 class="gd-h2">The monthly debit, step by step</h2><ol class="gd-flow"><li><b>1</b><span>Notice day</span><em>10 days before: your invoices and one email with the total</em></li><li><b>2</b><span>The 15th</span><em>Each invoice is debited from your account</em></li><li><b>3</b><span>Cleared</span><em>The invoice shows Paid and you get a receipt</em></li><li><b>4</b><span>Insufficient funds?</span><em>A $50.00 Late Fee once, and the same amount tried again within 30 days</em></li></ol><ul class="gd-ul"><li>A debit is never more than its notice said. Each invoice shows &quot;will be debited on&quot; with the date.</li><li>If your bank returns a debit for insufficient funds, we add the $50.00 Late Fee to that invoice once and try the original amount again within 30 days, as section 4.4 of your Enrollment Agreement sets out. The Late Fee is collected with your next debit.</li><li>Returned for another reason (for example a closed account)? We do not try again and add no Late Fee. We pause your debit and email you: pay the invoice from its page, or set up a new account under Banking.</li><li>Returned again after the retry? The invoice is in arrears and we contact you.</li><li>You can always pay an invoice by card from its page before the debit day.</li><li>On your bank statement the debit shows our company&#39;s legal name, operating as CarmaCars.</li></ul></section><section class="gd-task" id="fees-payments-and-payouts-set-up-the-automatic-debit" data-gd-task><h2 class="gd-h2">Set up the automatic debit</h2><p class="gd-p">Do this once. Without it, we email you on each notice day to set it up.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Banking</b>. Under Automatic debit of your fees, press <b class="gd-ui">Set up pre-authorized debit</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Read the agreement and press <b class="gd-ui">Continue to my bank details</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Enter your bank details and press <b class="gd-ui">Save the bank account</b>. Banking then shows the account and the next debit.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/banking</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/752"><img src="/guides/img/owner-07-banking-desktop-52316739.jpg" alt="" loading="lazy" decoding="async" width="1440" height="752"><span class="gd-pin" style="left:96.2%;top:36.8%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="fees-payments-and-payouts-pay-an-invoice-now" data-gd-task><h2 class="gd-h2">Pay an invoice now</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Invoices, then the invoice. It lists what it covers and the balance.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose Card (paid at once) and press <b class="gd-ui">Pay $...</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Or choose Pre-authorized debit (from a Canadian bank account, clears in 3 to 5 business days) and press <b class="gd-ui">Authorize debit of $...</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Prefer Interac e-Transfer? Send the amount to billing@carmacars.ca with the invoice number in the message.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/invoices/INV-1050</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/742"><img src="/guides/img/owner-06-invoice-desktop-bba2c020.jpg" alt="" loading="lazy" decoding="async" width="1440" height="742"><span class="gd-pin" style="left:6.9%;top:52.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:38.2%;top:52.6%" aria-hidden="true">3</span><span class="gd-pin" style="left:11.5%;top:80.5%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Paid us by e-Transfer, cheque, cash or bank transfer? Once we record it, the invoice says &quot;Paid by e-Transfer on&quot; the date, you get a receipt by email, and the automatic debit does not take that amount. Paid part of it? The invoice shows Partly paid and only the rest is debited.</div></aside></section><section class="gd-task" id="fees-payments-and-payouts-tell-us-where-to-pay-you" data-gd-task><h2 class="gd-h2">Tell us where to pay you</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Banking</b>. Under Where we pay you, choose Bank transfer or e-Transfer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Fill in Account holder, Institution number, Transit number and Account number (or your e-Transfer email).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Submit payout details</b>. For your security we confirm new details by phone before we use them.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/banking</span></div><div class="gd-imgwrap" style="aspect-ratio:990/642"><img src="/guides/img/owner-07-banking-desktop-87b2ffe3.jpg" alt="" loading="lazy" decoding="async" width="990" height="642"><span class="gd-pin" style="left:50.5%;top:25.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:90.9%;top:45.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:30.3%;top:89.7%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fees-payments-and-payouts-statements-and-payouts" data-gd-task><h2 class="gd-h2">Statements and payouts</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Statements: one a month, once approved by CarmaCars. Open one to see every booking, the revenue share, deductions and the payout.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download PDF</b> to keep a copy. We also email it to you with the PDF attached.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Payouts shows what was paid to you and when. Payouts are made on the 10th for the month before.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/statements/f27936a8-9bfb-4280-81ae-c67ec47febe1</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/792"><img src="/guides/img/owner-09-statement-desktop-fc5f9ea5.jpg" alt="" loading="lazy" decoding="async" width="1440" height="792"><span class="gd-pin" style="left:16%;top:30.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:66%;top:40.9%" aria-hidden="true">1</span></div></div></figure></div></section>');
select app.guide_release_section('owner', 'documents-and-forms', 'chapter', 'fees-payments-and-payouts', 'Your signed agreements, uploads and government forms are under Documents. Some forms are filled for you; Forms C and D are signed on paper with witnesses.

## Sign everything at once

Everything you sign on screen is in one place: Home shows how many are signed ("2 of 5 signed") and opens it with Check and sign.

1. Press **Check and sign** on Home (or open `carmacars.ca/owner/sign`). The list at the top shows each document: signed, in this package, or done elsewhere (Forms C and D, the bank debit).
2. Check the key values: your name, address, each car with its VIN and plate, your fees and Revenue Share. Something wrong? Press **Fix** next to it, change it, and come back.
3. Open any document to read it word for word: the agreements, the schedules, Forms A and B, and the official registry forms that are ready.
4. Tap **All of these** for the statements the agreement asks you to initial (your initials are filled in), then press **Sign all**.
5. Your name on file is your signature. One signature is applied to each document; CarmaCars countersigns at once and every signed copy is in Documents.

> Good to know: Form A (the trust declaration) is for cars under the Co-Registrant or Transfer method; Form B (the lease summary) for cars under a Lease method. No witness is needed: they are in the same package. You can also sign one on its own page from Documents.

> Tip: Signed one of your documents on paper instead? Send us the scan. Once we record it, Documents shows it as Signed on paper and we do not ask again.

## Forms C and D, signed with witnesses

Form D is a limited power of attorney (two witnesses). Form C is the lender or lessor permission for a financed or leased car (one witness).

1. Open Documents. Under Forms to sign with witnesses, press **Print the form**. It is filled in, and every spot to sign or initial is marked SIGN HERE or INITIAL HERE.
2. Sign it in front of your witnesses. They sign and print their names in their spots.
3. Type each witness''s full name in the boxes.
4. On your phone, press **Take a photo of the signed page**: one photo of each page. A PDF scan works too (**Or choose a file**).

![](/guides/img/owner-12-forms-c-d-desktop-21fbbe79.jpg "desktop; size: 1440 742; address: carmacars.ca/owner/documents; pins: 1 21.5 32.5, 3 69.4 50.7, 4 69.4 60.4")

> Tip: We check the photo and approve it, or send it back with what to fix. You get an email either way, and the page shows the status.

> Good to know: Why paper for these two? The forms need witnesses who sign in person, and Form D is a power of attorney, which cannot be signed electronically in Ontario.

## Government forms filled for you

Each car''s registry forms are prepared from your records. Until we load the official PDF, you get a data sheet with the values.

1. Open Documents and choose a form marked "Official form, filled for you".
2. Press **Download the filled form** and check each value.
3. To sign it on screen, draw your signature in the box, then press **Sign and save**. Forms ready to sign are also in the package on **Check and sign**, signed with the same one signature. The signed copy is kept with your documents.

![](/guides/img/owner-13-official-form-desktop-48614913.jpg "desktop; size: 1440 732; address: carmacars.ca/owner/documents/forms/e85d4214-54c8-49af-87e0-7776a5901810/official; pins: 2 22.2 29.5, 3 50.0 95.5")

> Watch out: If the registry office asks for an ink signature, print the filled form and sign it there. You pay ServiceOntario, the inspection station and the appraiser directly.
', 'Documents and forms', 'Agreements, government forms, Forms C and D, and official forms filled for you.',
  'Your signed agreements, uploads and government forms are under Documents. Some forms are filled for you; Forms C and D are signed with witnesses.

## Sign everything at once

Everything you sign on screen is in one place: Home shows how many are signed ("2 of 5 signed") and opens it with Check and sign.

1. Press **Check and sign** on Home (or open `carmacars.ca/owner/sign`). The list at the top shows each document: signed, in this package, or done elsewhere (Forms C and D, the bank debit).
2. Check the key values: your name, address, each car with its VIN and plate, your fees and Revenue Share. Something wrong? Press **Fix** next to it, change it, and come back.
3. Open any document to read it word for word: the agreements, the schedules, Forms A and B, and the official registry forms that are ready.
4. Tap **All of these** for the statements the agreement asks you to initial (your initials are filled in), then press **Sign all**.
5. Your name on file is your signature. One signature is applied to each document; CarmaCars countersigns at the same moment and every signed copy is in Documents.

> Two owners: A car with a second owner on its ownership? Each owner named in the Title Schedule signs. The other owner gets their own link by email and signs the same documents on their phone or computer. The agreements take effect when the last owner signs; CarmaCars countersigns then.

> Good to know: Form A (the trust declaration) is for cars under the Co-Registrant or Transfer method; Form B (the lease summary) for cars under a Lease method. No witness is needed: they are in the same package. You can also sign one on its own page from Documents.

> Tip: Signed one of your documents on paper instead? Send us the scan. Once we record it, Documents shows it as Signed on paper and we do not ask again.

## Form C on screen, with your witness beside you

Form C is the lender or lessor permission for a financed or leased car. It needs one witness, and you can sign it on screen when your witness is with you.

1. Open Documents. Under Forms to sign with witnesses, press Sign Form C on screen instead.
2. Initial each of the three acknowledgments, and type Your initials.
3. Sign: draw your signature in the box, or use your name.
4. Hand the device to your witness, another adult. They type their full name and tick the statement "I witnessed (your name) sign in my presence." Press **Sign Form C**.

![](/guides/img/owner-16-form-c-screen-desktop-faa92983.jpg "desktop; size: 790 980; address: carmacars.ca/owner/documents/form-c/b39a2a4e-6dcb-459c-b7c0-393f78919d91; pins: 2 5.7 13.6, 3 32.9 55.1, 4 6.3 82.2")

## Forms C and D on paper, signed with witnesses

Form D is a limited power of attorney (two witnesses), signed on paper. Form C can be signed on paper too, with one witness.

1. Open Documents. Under Forms to sign with witnesses, press **Print the form**. It is filled in, and every spot to sign or initial is marked SIGN HERE or INITIAL HERE.
2. Sign it in front of your witnesses. They sign and print their names in their spots.
3. Type each witness''s full name in the boxes.
4. On your phone, press **Take a photo of the signed page**: one photo of each page. A PDF scan works too (**Or choose a file**).

![](/guides/img/owner-12-forms-c-d-desktop-21fbbe79.jpg "desktop; size: 1440 742; address: carmacars.ca/owner/documents; pins: 1 21.5 32.5, 3 69.4 50.7, 4 69.4 60.4")

> Tip: We check the photo and approve it, or send it back with what to fix. You get an email either way, and the page shows the status.

> Good to know: Why paper for Form D? It is a power of attorney, which cannot be signed electronically in Ontario, and its two witnesses sign in person.

## Government forms filled for you

Each car''s registry forms are prepared from your records. Until we load the official PDF, you get a data sheet with the values.

1. Open Documents and choose a form marked "Official form, filled for you".
2. Press **Download the filled form** and check each value.
3. To sign it on screen, draw your signature in the box, then press **Sign and save**. Forms ready to sign are also in the package on **Check and sign**, signed with the same one signature. The signed copy is kept with your documents.

![](/guides/img/owner-13-official-form-desktop-48614913.jpg "desktop; size: 1440 732; address: carmacars.ca/owner/documents/forms/7624af13-b86c-4add-a2e7-b11651149086/official; pins: 2 22.2 29.5, 3 50.0 95.5")

> Watch out: If the registry office asks for an ink signature, print the filled form and sign it there. You pay ServiceOntario, the inspection station and the appraiser directly.
',
  '<p class="gd-p">Your signed agreements, uploads and government forms are under Documents. Some forms are filled for you; Forms C and D are signed with witnesses.</p><section class="gd-task" id="documents-and-forms-sign-everything-at-once" data-gd-task><h2 class="gd-h2">Sign everything at once</h2><p class="gd-p">Everything you sign on screen is in one place: Home shows how many are signed (&quot;2 of 5 signed&quot;) and opens it with Check and sign.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Check and sign</b> on Home (or open <span class="gd-url">carmacars.ca/owner/sign</span>). The list at the top shows each document: signed, in this package, or done elsewhere (Forms C and D, the bank debit).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the key values: your name, address, each car with its VIN and plate, your fees and Revenue Share. Something wrong? Press <b class="gd-ui">Fix</b> next to it, change it, and come back.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open any document to read it word for word: the agreements, the schedules, Forms A and B, and the official registry forms that are ready.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Tap <b class="gd-ui">All of these</b> for the statements the agreement asks you to initial (your initials are filled in), then press <b class="gd-ui">Sign all</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Your name on file is your signature. One signature is applied to each document; CarmaCars countersigns at the same moment and every signed copy is in Documents.</div></li></ol></div><aside class="gd-box"><div>Two owners: A car with a second owner on its ownership? Each owner named in the Title Schedule signs. The other owner gets their own link by email and signs the same documents on their phone or computer. The agreements take effect when the last owner signs; CarmaCars countersigns then.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Form A (the trust declaration) is for cars under the Co-Registrant or Transfer method; Form B (the lease summary) for cars under a Lease method. No witness is needed: they are in the same package. You can also sign one on its own page from Documents.</div></aside><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Signed one of your documents on paper instead? Send us the scan. Once we record it, Documents shows it as Signed on paper and we do not ask again.</div></aside></section><section class="gd-task" id="documents-and-forms-form-c-on-screen-with-your-witness-beside-you" data-gd-task><h2 class="gd-h2">Form C on screen, with your witness beside you</h2><p class="gd-p">Form C is the lender or lessor permission for a financed or leased car. It needs one witness, and you can sign it on screen when your witness is with you.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Documents. Under Forms to sign with witnesses, press Sign Form C on screen instead.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Initial each of the three acknowledgments, and type Your initials.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Sign: draw your signature in the box, or use your name.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Hand the device to your witness, another adult. They type their full name and tick the statement &quot;I witnessed (your name) sign in my presence.&quot; Press <b class="gd-ui">Sign Form C</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/documents/form-c/b39a2a4e-6dcb-459c-b7c0-393f78919d91</span></div><div class="gd-imgwrap" style="aspect-ratio:790/980"><img src="/guides/img/owner-16-form-c-screen-desktop-faa92983.jpg" alt="" loading="lazy" decoding="async" width="790" height="980"><span class="gd-pin" style="left:5.7%;top:13.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:32.9%;top:55.1%" aria-hidden="true">3</span><span class="gd-pin" style="left:6.3%;top:82.2%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="documents-and-forms-forms-c-and-d-on-paper-signed-with-witnesses" data-gd-task><h2 class="gd-h2">Forms C and D on paper, signed with witnesses</h2><p class="gd-p">Form D is a limited power of attorney (two witnesses), signed on paper. Form C can be signed on paper too, with one witness.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Documents. Under Forms to sign with witnesses, press <b class="gd-ui">Print the form</b>. It is filled in, and every spot to sign or initial is marked SIGN HERE or INITIAL HERE.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Sign it in front of your witnesses. They sign and print their names in their spots.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Type each witness&#39;s full name in the boxes.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On your phone, press <b class="gd-ui">Take a photo of the signed page</b>: one photo of each page. A PDF scan works too (<b class="gd-ui">Or choose a file</b>).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/documents</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/742"><img src="/guides/img/owner-12-forms-c-d-desktop-21fbbe79.jpg" alt="" loading="lazy" decoding="async" width="1440" height="742"><span class="gd-pin" style="left:21.5%;top:32.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:69.4%;top:50.7%" aria-hidden="true">3</span><span class="gd-pin" style="left:69.4%;top:60.4%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>We check the photo and approve it, or send it back with what to fix. You get an email either way, and the page shows the status.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Why paper for Form D? It is a power of attorney, which cannot be signed electronically in Ontario, and its two witnesses sign in person.</div></aside></section><section class="gd-task" id="documents-and-forms-government-forms-filled-for-you" data-gd-task><h2 class="gd-h2">Government forms filled for you</h2><p class="gd-p">Each car&#39;s registry forms are prepared from your records. Until we load the official PDF, you get a data sheet with the values.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Documents and choose a form marked &quot;Official form, filled for you&quot;.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download the filled form</b> and check each value.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To sign it on screen, draw your signature in the box, then press <b class="gd-ui">Sign and save</b>. Forms ready to sign are also in the package on <b class="gd-ui">Check and sign</b>, signed with the same one signature. The signed copy is kept with your documents.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/documents/forms/7624af13-b86c-4add-a2e7-b11651149086/official</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/732"><img src="/guides/img/owner-13-official-form-desktop-48614913.jpg" alt="" loading="lazy" decoding="async" width="1440" height="732"><span class="gd-pin" style="left:22.2%;top:29.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:50%;top:95.5%" aria-hidden="true">3</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>If the registry office asks for an ink signature, print the filled form and sign it there. You pay ServiceOntario, the inspection station and the appraiser directly.</div></aside></section>');
select app.guide_release_section('owner', 'quick-reference', 'reference', 'notices-profile-and-leaving', '### Where things are

| Item | What it is for |
| --- | --- |
| **Home** | Next thing to do, your cars, money, next debit |
| **Vehicles** | Each car: terms, checklist, uploads, photos, Leaving |
| **Bookings** | Calendar, all bookings, Book my own car |
| **Invoices** | Fee invoices and Pay $... |
| **Statements** | One a month, Download PDF |
| **Payouts** | What was paid and when |
| **Documents** | Agreements, forms, Forms C and D |
| **Banking** | Automatic debit, where we pay you |
| **Notifications** | Our messages |
| **Profile** | Contact details, password |

### Top tasks

1. **Sign everything at once** ›*Check and sign
2. **Set up the monthly debit** ›*Set up pre-authorized debit
3. **Pay an invoice now** ›*the invoice›*Pay $...
4. **Payout details** ›*Where we pay you
5. **Forms C and D** ›*Take a photo of the signed page
6. **Book your own car** ›*Book my own car
7. **New listing photos** ›*the car›*Take new photos
8. **Leave the program** ›*the car›*Give notice

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **A debit was returned** | You get an email with the reason. Pay the invoice from its page, or keep money in the account for the retry. |
', 'Quick reference', 'One page with the essentials.',
  '### Where things are

| Item | What it is for |
| --- | --- |
| **Home** | Next thing to do, your cars, money, next debit |
| **Vehicles** | Each car: terms, checklist, uploads, photos, Leaving |
| **Bookings** | Calendar, all bookings, Book my own car |
| **Invoices** | Fee invoices and Pay $... |
| **Statements** | One a month, Download PDF |
| **Payouts** | What was paid and when |
| **Documents** | Agreements, forms, Forms C and D |
| **Banking** | Automatic debit, where we pay you |
| **Notifications** | Our messages |
| **Profile** | Contact details, password |

### Top tasks

1. *Sign everything at once:* **Home** > **Check and sign**
2. *Set up the monthly debit:* **Banking** > **Set up pre-authorized debit**
3. *Pay an invoice now:* **Invoices**, the invoice, then **Pay $...**
4. *Payout details:* **Banking** > **Where we pay you**
5. *Forms C and D:* **Documents** > **Sign Form C on screen instead** or **Take a photo of the signed page**
6. *Book your own car:* **Bookings** > **Book my own car**
7. *New listing photos:* **Vehicles**, the car, then **Take new photos**
8. *Leave the program:* **Vehicles**, the car, then **Give notice**

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **A debit was returned** | You get an email with the reason. Insufficient funds: keep the money in the account for the retry, or pay the invoice from its page. Any other reason: pay from the invoice''s page or set up a new account under Banking. |
',
  '<h3 class="gd-h3">Where things are</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Item</th><th scope="col">What it is for</th></tr></thead><tbody><tr><td><b class="gd-ui">Home</b></td><td>Next thing to do, your cars, money, next debit</td></tr><tr><td><b class="gd-ui">Vehicles</b></td><td>Each car: terms, checklist, uploads, photos, Leaving</td></tr><tr><td><b class="gd-ui">Bookings</b></td><td>Calendar, all bookings, Book my own car</td></tr><tr><td><b class="gd-ui">Invoices</b></td><td>Fee invoices and Pay $...</td></tr><tr><td><b class="gd-ui">Statements</b></td><td>One a month, Download PDF</td></tr><tr><td><b class="gd-ui">Payouts</b></td><td>What was paid and when</td></tr><tr><td><b class="gd-ui">Documents</b></td><td>Agreements, forms, Forms C and D</td></tr><tr><td><b class="gd-ui">Banking</b></td><td>Automatic debit, where we pay you</td></tr><tr><td><b class="gd-ui">Notifications</b></td><td>Our messages</td></tr><tr><td><b class="gd-ui">Profile</b></td><td>Contact details, password</td></tr></tbody></table></div><h3 class="gd-h3">Top tasks</h3><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><em>Sign everything at once:</em> <b class="gd-ui">Home</b> &gt; <b class="gd-ui">Check and sign</b></div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><em>Set up the monthly debit:</em> <b class="gd-ui">Banking</b> &gt; <b class="gd-ui">Set up pre-authorized debit</b></div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><em>Pay an invoice now:</em> <b class="gd-ui">Invoices</b>, the invoice, then <b class="gd-ui">Pay $...</b></div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><em>Payout details:</em> <b class="gd-ui">Banking</b> &gt; <b class="gd-ui">Where we pay you</b></div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><em>Forms C and D:</em> <b class="gd-ui">Documents</b> &gt; <b class="gd-ui">Sign Form C on screen instead</b> or <b class="gd-ui">Take a photo of the signed page</b></div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><em>Book your own car:</em> <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Book my own car</b></div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><em>New listing photos:</em> <b class="gd-ui">Vehicles</b>, the car, then <b class="gd-ui">Take new photos</b></div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t"><em>Leave the program:</em> <b class="gd-ui">Vehicles</b>, the car, then <b class="gd-ui">Give notice</b></div></li></ol></div><h3 class="gd-h3">If something goes wrong</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">What you see</th><th scope="col">What to do</th></tr></thead><tbody><tr><td><b class="gd-ui">A link says it expired</b></td><td>Links in our emails work for 24 hours, once. Press <b class="gd-ui">Send me a new link</b> on that page.</td></tr><tr><td><b class="gd-ui">&quot;Error 1102&quot; on a page</b></td><td>A short limit on our web host. Reload the page. You are still signed in.</td></tr><tr><td><b class="gd-ui">&quot;That email and password do not match an account.&quot;</b></td><td>Check the address, or use <b class="gd-ui">Set a new password</b> on the sign-in page.</td></tr><tr><td><b class="gd-ui">A debit was returned</b></td><td>You get an email with the reason. Insufficient funds: keep the money in the account for the retry, or pay the invoice from its page. Any other reason: pay from the invoice&#39;s page or set up a new account under Banking.</td></tr></tbody></table></div>');
select app.guide_release_section('admin', 'start-here', 'start', null, '### Who this guide is for

CarmaCars Admins: the owner of the business and anyone an Admin invites with the Admin role. Admin sees and changes everything, and can open any other portal as one of its people.

### What you need

- Your Admin email address. The owner''s account is rent@carmacars.ca
- Access to that inbox (links work for 24 hours, once)
- A computer for most work. Admin also works on a phone, with the menu as one scrolling strip

## Your first sign-in

1. First time? Go to `carmacars.ca/reset-password`, enter your Admin email and press **Send the link**.
2. Open the email "Reset your CarmaCars password" within 24 hours and press **Choose a new password**.
3. Type a New password of 8 characters or more and press **Save the new password**. You land in Admin.
4. Next time, sign in at `carmacars.ca/sign-in` with that email and password.

![](/guides/img/public-11-reset-password-phone-f4497631.jpg "phone; size: 390 525; pins: 1 95.4 59.2")

> Good to know: A link that has expired or was already used opens "This link has expired" with **Send me a new link**. Invited by another Admin? The invitation email works the same way.
', 'Start here', 'Who this is for and your first sign-in.',
  '### Who this guide is for

The CarmaCars Admin: the owner of the business, signed in as rent@carmacars.ca. Admin sees and changes everything, and can open any other portal as one of its people. Staff work in the staff portal instead.

### What you need

- The Admin email address: rent@carmacars.ca. Only that address can hold the Admin role (Admin > Settings > Admin access lists it)
- Access to that inbox (links work for 24 hours, once)
- A computer for most work. Admin also works on a phone, with the whole menu behind one Menu button

## Your first sign-in

1. First time? Go to `carmacars.ca/reset-password`, enter your Admin email and press **Send the link**.
2. Open the email "Reset your CarmaCars password" within 24 hours and press **Choose a new password**.
3. Type a New password of 8 characters or more and press **Save the new password**. You land in Admin.
4. Next time, sign in at `carmacars.ca/sign-in` with that email and password.

![](/guides/img/public-11-reset-password-phone-f4497631.jpg "phone; size: 390 525; pins: 1 95.4 59.2")

> Good to know: A link that has expired or was already used opens "This link has expired" with **Send me a new link**. Invited by another Admin? The invitation email works the same way.
',
  '<h3 class="gd-h3">Who this guide is for</h3><p class="gd-p">The CarmaCars Admin: the owner of the business, signed in as rent@carmacars.ca. Admin sees and changes everything, and can open any other portal as one of its people. Staff work in the staff portal instead.</p><h3 class="gd-h3">What you need</h3><ul class="gd-ul"><li>The Admin email address: rent@carmacars.ca. Only that address can hold the Admin role (Admin &gt; Settings &gt; Admin access lists it)</li><li>Access to that inbox (links work for 24 hours, once)</li><li>A computer for most work. Admin also works on a phone, with the whole menu behind one Menu button</li></ul><section class="gd-task" id="start-here-your-first-sign-in" data-gd-task><h2 class="gd-h2">Your first sign-in</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">First time? Go to <span class="gd-url">carmacars.ca/reset-password</span>, enter your Admin email and press <b class="gd-ui">Send the link</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open the email &quot;Reset your CarmaCars password&quot; within 24 hours and press <b class="gd-ui">Choose a new password</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Type a New password of 8 characters or more and press <b class="gd-ui">Save the new password</b>. You land in Admin.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Next time, sign in at <span class="gd-url">carmacars.ca/sign-in</span> with that email and password.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/525"><img src="/guides/img/public-11-reset-password-phone-f4497631.jpg" alt="" loading="lazy" decoding="async" width="390" height="525"><span class="gd-pin" style="left:95.4%;top:59.2%" aria-hidden="true">1</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A link that has expired or was already used opens &quot;This link has expired&quot; with <b class="gd-ui">Send me a new link</b>. Invited by another Admin? The invitation email works the same way.</div></aside></section>');
select app.guide_release_section('admin', 'getting-around-admin', 'chapter', 'start-here', 'Admin opens on Today: what needs you now. The rail on the left groups every screen into Operate, Fleet, Money, Recover, People and Setup.

## Today

Start every shift here.

1. Alerts: site setup still to finish, failed scheduled jobs and email use. Each has a link to fix it.
2. The tiles count requests waiting, offers out, late returns, failed payments and fleet use.
3. Requests waiting, pickups and returns today, late returns and money this month.
4. Press **Work the requests** to go straight to the queue, or **Calendar** for the master calendar.

![](/guides/img/admin-01-today-desktop-c60b8ab5.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin; pins: 1 96.9 22.7, 2 24.2 40.0, 3 49.7 53.0, 4 80.6 11.8")

## The rail

On a phone the rail becomes one scrolling strip at the top.

| Group | Screens |
| --- | --- |
| Operate | Today, Requests, Bookings, Calendar, Tasks |
| Fleet | Vehicles, Listings, Similar cars, Bulk rates |
| Money | Payments and refunds, Insurer invoices, Owner invoices, Owner debits, Owner statements, Payouts, Company statements, Expenses, Reconciliation |
| Recover | Tolls and tickets, Damage, Incidents and claims |
| People | Portals and sign-in, Staff, Owners, Owner forms, Investors, Reviews, Email, Audit log |
| Setup | Settings |

## Keyboard shortcuts

Press g, then a letter. Press / to jump to the page''s search box.

| Keys | Opens | Keys | Opens |
| --- | --- | --- | --- |
| g t | Today | g v | Vehicles |
| g r | Requests | g l | Listings |
| g b | Bookings | g m | Money |
| g c | Calendar | g o | Tolls |
| g k | Tasks | g s | Settings |
', 'Getting around Admin', 'To do, the menu, search, keyboard shortcuts and your other portals.',
  'Admin opens on To do: what needs you now, most urgent first. The menu groups every screen into seven groups: Today, Bookings, Cars, Owners and partners, Money, People and Settings. Search finds any booking, car or person.

## To do

Start every shift here. Each line counts what is waiting and has one button to deal with it.

1. The list is in order of urgency: owner applications, booking requests, changes renters asked for, failed payments, agreements to countersign, tolls, listings, plates not checked, insurance and cars using sample photos.
2. Press the button on a line to go straight to that work. A line with nothing waiting moves to the bottom, under "more with nothing waiting".
3. Below the list: today''s pickups (ready or not ready) and today''s returns (due or late).
4. Press **Overview** for the money, fleet and queue figures and the alerts.

![](/guides/img/admin-01-today-desktop-ea48309c.jpg "desktop; size: 1440 900; address: carmacars.ca/admin; pins: 1 22.6 31.6, 2 90.3 31.7, 3 18.4 90.2, 4 94.4 22.2")

## The menu

The current group is open, with its pages; press another group to open it. On a phone the whole menu sits behind one Menu button that says where you are.

| Group | Pages |
| --- | --- |
| Today | To do, Overview, Tasks |
| Bookings | Requests, Bookings, Calendar, Add a rental, Damage, Incidents and claims, Reviews |
| Cars | Vehicles, Listings, Similar cars, Retire or delete, Rates for many cars |
| Owners and partners | Applications, Owners, Partners, Owner forms, Paid and signed |
| Money | Owner invoices, Owner debits, Payments and refunds, Owner statements, Company statements, Payouts, Tolls and tickets, Insurer invoices, Reconciliation, Expenses |
| People | Renters, Staff, Investors, Portals and view as |
| Settings | All settings, Site, Program, Forms, Guides, Emails, Email log, Sample photos, Audit log |

![On a phone: press Menu (1), then a group (2), then the page (3).](/guides/img/admin-31-menu-phone-667dc2fd.jpg "phone; size: 390 715; pins: 1 10.3 28.7, 2 76.9 42.4, 3 76.9 48.3")

## Search

The search box sits at the top of the menu, on every page.

1. Type a booking number (CC-1042), a plate, a VIN, or a name or email address.
2. Press **Search** (or Enter). Results come in groups: bookings, cars, owners, partners and renters. Open one to go to its page.

![](/guides/img/admin-32-search-desktop-ca548a70.jpg "desktop; size: 1440 420; address: carmacars.ca/admin/search?q=CC-10057; pins: 1 7.4 45.2, 2 95.0 46.9")

## Keyboard shortcuts

Press g, then a letter. Press / to jump to the search box.

| Keys | Opens | Keys | Opens |
| --- | --- | --- | --- |
| g t | To do | g v | Vehicles |
| g r | Requests | g l | Listings |
| g b | Bookings | g a | Applications |
| g c | Calendar | g o | Owners |
| g k | Tasks | g m | Payments and refunds |
| g s | All settings | / | Search |
',
  '<p class="gd-p">Admin opens on To do: what needs you now, most urgent first. The menu groups every screen into seven groups: Today, Bookings, Cars, Owners and partners, Money, People and Settings. Search finds any booking, car or person.</p><section class="gd-task" id="getting-around-admin-to-do" data-gd-task><h2 class="gd-h2">To do</h2><p class="gd-p">Start every shift here. Each line counts what is waiting and has one button to deal with it.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The list is in order of urgency: owner applications, booking requests, changes renters asked for, failed payments, agreements to countersign, tolls, listings, plates not checked, insurance and cars using sample photos.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press the button on a line to go straight to that work. A line with nothing waiting moves to the bottom, under &quot;more with nothing waiting&quot;.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Below the list: today&#39;s pickups (ready or not ready) and today&#39;s returns (due or late).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Overview</b> for the money, fleet and queue figures and the alerts.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-01-today-desktop-ea48309c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:22.6%;top:31.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:90.3%;top:31.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:18.4%;top:90.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:94.4%;top:22.2%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="getting-around-admin-the-menu" data-gd-task><h2 class="gd-h2">The menu</h2><p class="gd-p">The current group is open, with its pages; press another group to open it. On a phone the whole menu sits behind one Menu button that says where you are.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Group</th><th scope="col">Pages</th></tr></thead><tbody><tr><td>Today</td><td>To do, Overview, Tasks</td></tr><tr><td>Bookings</td><td>Requests, Bookings, Calendar, Add a rental, Damage, Incidents and claims, Reviews</td></tr><tr><td>Cars</td><td>Vehicles, Listings, Similar cars, Retire or delete, Rates for many cars</td></tr><tr><td>Owners and partners</td><td>Applications, Owners, Partners, Owner forms, Paid and signed</td></tr><tr><td>Money</td><td>Owner invoices, Owner debits, Payments and refunds, Owner statements, Company statements, Payouts, Tolls and tickets, Insurer invoices, Reconciliation, Expenses</td></tr><tr><td>People</td><td>Renters, Staff, Investors, Portals and view as</td></tr><tr><td>Settings</td><td>All settings, Site, Program, Forms, Guides, Emails, Email log, Sample photos, Audit log</td></tr></tbody></table></div><div class="gd-figblock"><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/715"><img src="/guides/img/admin-31-menu-phone-667dc2fd.jpg" alt="On a phone: press Menu (1), then a group (2), then the page (3)." loading="lazy" decoding="async" width="390" height="715"><span class="gd-pin" style="left:10.3%;top:28.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:76.9%;top:42.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:76.9%;top:48.3%" aria-hidden="true">3</span></div></div><figcaption>On a phone: press Menu (1), then a group (2), then the page (3).</figcaption></figure></div></section><section class="gd-task" id="getting-around-admin-search" data-gd-task><h2 class="gd-h2">Search</h2><p class="gd-p">The search box sits at the top of the menu, on every page.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type a booking number (CC-1042), a plate, a VIN, or a name or email address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Search</b> (or Enter). Results come in groups: bookings, cars, owners, partners and renters. Open one to go to its page.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/search?q=CC-10057</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/420"><img src="/guides/img/admin-32-search-desktop-ca548a70.jpg" alt="" loading="lazy" decoding="async" width="1440" height="420"><span class="gd-pin" style="left:7.4%;top:45.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:95%;top:46.9%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="getting-around-admin-keyboard-shortcuts" data-gd-task><h2 class="gd-h2">Keyboard shortcuts</h2><p class="gd-p">Press g, then a letter. Press / to jump to the search box.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Keys</th><th scope="col">Opens</th><th scope="col">Keys</th><th scope="col">Opens</th></tr></thead><tbody><tr><td>g t</td><td>To do</td><td>g v</td><td>Vehicles</td></tr><tr><td>g r</td><td>Requests</td><td>g l</td><td>Listings</td></tr><tr><td>g b</td><td>Bookings</td><td>g a</td><td>Applications</td></tr><tr><td>g c</td><td>Calendar</td><td>g o</td><td>Owners</td></tr><tr><td>g k</td><td>Tasks</td><td>g m</td><td>Payments and refunds</td></tr><tr><td>g s</td><td>All settings</td><td>/</td><td>Search</td></tr></tbody></table></div></section>');
select app.guide_release_section('admin', 'people-and-access', 'chapter', 'getting-around-admin', 'Let people in, help them back in when they are locked out, and see exactly what they see. Every step is recorded in the audit log.

## Portals and sign-in

Open ›*Portals and sign-in. Every portal has a card.

1. Each card links to **Its sign-in page**, the address to send that person.
2. Choose a person in the list on the card.
3. Press **Open as this person** to see that portal as they see it.

![](/guides/img/admin-27-portals-desktop-0361bf61.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/portals; pins: 1 65.9 30.2, 2 58.1 39.4, 3 51.6 45.6")

## Invite a person

Invitations work for every role. The person gets our invitation email and chooses a password.

1. Under Invite a person, choose the Role: Admin, Staff (assistant), Field staff, Owner on file or Investor on file.
2. Fill in the Name and Email.
3. For staff, pick the Main function, and tick Also covers for any other function they help with. For field staff, pick the Field function.
4. Press **Invite**. The link in the email works for 24 hours.

![](/guides/img/admin-27-portals-desktop-c10725cb.jpg "desktop; size: 1230 360; address: carmacars.ca/admin/portals; pins: 1 18.8 40.8, 2 50.0 40.8, 3 18.8 66.7, 4 9.8 87.8")

> Tip: Someone who already signs in gets the new role at once, with no email. Owners and investors must be on file first: Admin > Owners and Admin > Investors also have a one-click invite for a record without a sign-in.

## Send a password link

For anyone who forgot their password or let their invitation expire.

1. Under People who can sign in, search by name or email.
2. On their row, press **Send password link**. They get "Reset your CarmaCars password", valid for 24 hours.
3. **View as (...)** on the same row opens their portal, read only.

![](/guides/img/admin-27-portals-desktop-ee9b3e94.jpg "desktop; size: 1230 440; address: carmacars.ca/admin/portals; pins: 1 74.8 6.6, 2 68.2 28.6, 3 84.1 28.6")

## View as: see what someone sees

1. A red banner says "Viewing as Name (email), read only." on every page.
2. Click around their portal. Nothing can be changed: every save is refused.
3. Press **Exit** to come back. A view also ends by itself after 30 minutes.

![](/guides/img/admin-28-view-as-desktop-f858e38c.jpg "desktop; size: 1440 620; address: carmacars.ca/owner; pins: 1 48.6 4.5, 3 94.4 4.5")

> Watch out: Can''t change anything in Admin? You may still be viewing as someone. Look for the red banner and press Exit.

## The audit log

›*Audit log shows who changed what, and when.

1. Changes lists every change with the person, the action, the table and the record. Data access lists lookups of private data.
2. Every View as is recorded (view_as_start), with the person viewed.
3. Search by table, record id or value.

![](/guides/img/admin-29-audit-desktop-b7504100.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/audit; pins: 1 22.6 31.1, 2 39.0 46.4, 3 89.6 20.7")

## Staff and roles

›*Staff and roles (also under ›*Staff).

1. Invite staff here too: Role, Name, Email, Main function and Also covers, then **Invite**.
2. Each row has **Send password link**, **View as (...)** and Limits (how much they may approve or refund).
3. Press **End access** to close their staff portal at once. **Restore** undoes it.

![](/guides/img/admin-26-staff-desktop-72287d0b.jpg "desktop; size: 1440 780; address: carmacars.ca/admin/settings/staff; pins: 1 20.8 59.0, 2 94.4 86.7, 3 83.3 92.6")

## Staff scorecards

See how each assistant is doing against the targets.

1. On a staff member''s row in Staff and roles, press **Scorecard**.
2. By week shows each measure (for example quote sent within 15 minutes) and the result for each week.
3. A task meets its target when it is done by its due time. Daily checks count when done by 9:00 and 18:00.

![](/guides/img/va-sales-05-scorecard-desktop-956a5a9e.jpg "desktop; size: 1230 350; address: carmacars.ca/va/scorecard; pins: 2 21.1 42.9")
', 'People and access', 'Portals and sign-in, invitations, password links, View as, staff and scorecards.',
  'Let people in, help them back in when they are locked out, and see exactly what they see. Every step is recorded in the audit log.

## Portals and sign-in

Open **People** > **Portals and view as**. Every portal has a card.

1. Each card links to **Its sign-in page**, the address to send that person.
2. Choose a person in the list on the card.
3. Press **Open as this person** to see that portal as they see it.

![](/guides/img/admin-27-portals-desktop-0361bf61.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/portals; pins: 1 65.9 30.2, 2 58.1 39.4, 3 51.6 45.6")

## Invite a person

Invitations work for staff, field staff, owners and investors. The person gets our invitation email and chooses a password.

1. Under Invite a person, choose the Role: Staff (assistant), Field staff, Owner on file or Investor on file. Admin is not offered: only rent@carmacars.ca can be an Admin.
2. Fill in the Name and Email.
3. For staff, pick the Main function, and tick Also covers for any other function they help with. For field staff, pick the Field function.
4. Press **Invite**. The link in the email works for 24 hours.

![](/guides/img/admin-27-portals-desktop-c10725cb.jpg "desktop; size: 1230 360; address: carmacars.ca/admin/portals; pins: 1 18.8 40.8, 2 50.0 40.8, 3 18.8 66.7, 4 9.8 87.8")

> Tip: Someone who already signs in gets the new role at once, with no email. Owners and investors must be on file first: Owners and partners > Owners and People > Investors also have a one-click invite for a record without a sign-in.

## Send a password link

For anyone who forgot their password or let their invitation expire.

1. Under People who can sign in, search by name or email.
2. On their row, press **Send password link**. They get "Reset your CarmaCars password", valid for 24 hours.
3. **View as (...)** on the same row opens their portal, read only.

![](/guides/img/admin-27-portals-desktop-ee9b3e94.jpg "desktop; size: 1230 440; address: carmacars.ca/admin/portals; pins: 1 74.8 6.6, 2 68.2 28.6, 3 84.1 28.6")

## View as: see what someone sees

1. A red banner says "Viewing as Name (email), read only." on every page.
2. Click around their portal. Nothing can be changed: every save is refused.
3. Press **Exit** to come back. A view also ends by itself after 30 minutes.

![](/guides/img/admin-28-view-as-desktop-f858e38c.jpg "desktop; size: 1440 620; address: carmacars.ca/owner; pins: 1 48.6 4.5, 3 94.4 4.5")

> Watch out: Can''t change anything in Admin? You may still be viewing as someone. Look for the red banner and press Exit.

## The audit log

**Settings** > **Audit log** shows who changed what, and when.

1. Changes lists every change with the person, the action, the table and the record. Data access lists lookups of private data.
2. Every View as is recorded (view_as_start), with the person viewed.
3. Search by table, record id or value.

![](/guides/img/admin-29-audit-desktop-b7504100.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/audit; pins: 1 22.6 31.1, 2 39.0 46.4, 3 89.6 20.7")

## Staff and roles

**People** > **Staff** opens Staff and roles.

1. Invite staff here too: Role, Name, Email, Main function and Also covers, then **Invite**.
2. Each row has **Send password link**, **View as (...)** and Limits (how much they may approve or refund).
3. Press **End access** to close their staff portal at once. **Restore** undoes it.

![](/guides/img/admin-26-staff-desktop-72287d0b.jpg "desktop; size: 1440 780; address: carmacars.ca/admin/settings/staff; pins: 1 20.8 59.0, 2 94.4 86.7, 3 83.3 92.6")

## Admin access

**Settings** > **All settings**, then Admin access. Who may hold the Admin role.

1. The list holds rent@carmacars.ca, and verify-admin@carmacars.ca, the automated test account the site''s nightly checks sign in with.
2. Below it: everyone who holds the Admin role now. Each must be on the list; the database refuses the Admin role to any other address.
3. Change the list only if the business''s Admin address changes.

## Staff scorecards

See how each assistant is doing against the targets.

1. On a staff member''s row in Staff and roles, press **Scorecard**.
2. By week shows each measure (for example quote sent within 15 minutes) and the result for each week.
3. A task meets its target when it is done by its due time. Daily checks count when done by 9:00 and 18:00.

![](/guides/img/va-sales-05-scorecard-desktop-956a5a9e.jpg "desktop; size: 1230 350; address: carmacars.ca/va/scorecard; pins: 2 21.1 42.9")
',
  '<p class="gd-p">Let people in, help them back in when they are locked out, and see exactly what they see. Every step is recorded in the audit log.</p><section class="gd-task" id="people-and-access-portals-and-sign-in" data-gd-task><h2 class="gd-h2">Portals and sign-in</h2><p class="gd-p">Open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Portals and view as</b>. Every portal has a card.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each card links to <b class="gd-ui">Its sign-in page</b>, the address to send that person.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose a person in the list on the card.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Open as this person</b> to see that portal as they see it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/portals</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/820"><img src="/guides/img/admin-27-portals-desktop-0361bf61.jpg" alt="" loading="lazy" decoding="async" width="1440" height="820"><span class="gd-pin" style="left:65.9%;top:30.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:58.1%;top:39.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:51.6%;top:45.6%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-invite-a-person" data-gd-task><h2 class="gd-h2">Invite a person</h2><p class="gd-p">Invitations work for staff, field staff, owners and investors. The person gets our invitation email and chooses a password.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Under Invite a person, choose the Role: Staff (assistant), Field staff, Owner on file or Investor on file. Admin is not offered: only rent@carmacars.ca can be an Admin.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Fill in the Name and Email.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">For staff, pick the Main function, and tick Also covers for any other function they help with. For field staff, pick the Field function.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Invite</b>. The link in the email works for 24 hours.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/portals</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/360"><img src="/guides/img/admin-27-portals-desktop-c10725cb.jpg" alt="" loading="lazy" decoding="async" width="1230" height="360"><span class="gd-pin" style="left:18.8%;top:40.8%" aria-hidden="true">1</span><span class="gd-pin" style="left:50%;top:40.8%" aria-hidden="true">2</span><span class="gd-pin" style="left:18.8%;top:66.7%" aria-hidden="true">3</span><span class="gd-pin" style="left:9.8%;top:87.8%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Someone who already signs in gets the new role at once, with no email. Owners and investors must be on file first: Owners and partners &gt; Owners and People &gt; Investors also have a one-click invite for a record without a sign-in.</div></aside></section><section class="gd-task" id="people-and-access-send-a-password-link" data-gd-task><h2 class="gd-h2">Send a password link</h2><p class="gd-p">For anyone who forgot their password or let their invitation expire.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Under People who can sign in, search by name or email.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">On their row, press <b class="gd-ui">Send password link</b>. They get &quot;Reset your CarmaCars password&quot;, valid for 24 hours.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">View as (...)</b> on the same row opens their portal, read only.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/portals</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/440"><img src="/guides/img/admin-27-portals-desktop-ee9b3e94.jpg" alt="" loading="lazy" decoding="async" width="1230" height="440"><span class="gd-pin" style="left:74.8%;top:6.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:68.2%;top:28.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:84.1%;top:28.6%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-view-as-see-what-someone-sees" data-gd-task><h2 class="gd-h2">View as: see what someone sees</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A red banner says &quot;Viewing as Name (email), read only.&quot; on every page.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Click around their portal. Nothing can be changed: every save is refused.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Exit</b> to come back. A view also ends by itself after 30 minutes.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/620"><img src="/guides/img/admin-28-view-as-desktop-f858e38c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="620"><span class="gd-pin" style="left:48.6%;top:4.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.4%;top:4.5%" aria-hidden="true">3</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Can&#39;t change anything in Admin? You may still be viewing as someone. Look for the red banner and press Exit.</div></aside></section><section class="gd-task" id="people-and-access-the-audit-log" data-gd-task><h2 class="gd-h2">The audit log</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Audit log</b> shows who changed what, and when.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Changes lists every change with the person, the action, the table and the record. Data access lists lookups of private data.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Every View as is recorded (view_as_start), with the person viewed.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Search by table, record id or value.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/audit</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/560"><img src="/guides/img/admin-29-audit-desktop-b7504100.jpg" alt="" loading="lazy" decoding="async" width="1440" height="560"><span class="gd-pin" style="left:22.6%;top:31.1%" aria-hidden="true">1</span><span class="gd-pin" style="left:39%;top:46.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:89.6%;top:20.7%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-staff-and-roles" data-gd-task><h2 class="gd-h2">Staff and roles</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Staff</b> opens Staff and roles.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Invite staff here too: Role, Name, Email, Main function and Also covers, then <b class="gd-ui">Invite</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each row has <b class="gd-ui">Send password link</b>, <b class="gd-ui">View as (...)</b> and Limits (how much they may approve or refund).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">End access</b> to close their staff portal at once. <b class="gd-ui">Restore</b> undoes it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/staff</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/780"><img src="/guides/img/admin-26-staff-desktop-72287d0b.jpg" alt="" loading="lazy" decoding="async" width="1440" height="780"><span class="gd-pin" style="left:20.8%;top:59%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.4%;top:86.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:83.3%;top:92.6%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-admin-access" data-gd-task><h2 class="gd-h2">Admin access</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, then Admin access. Who may hold the Admin role.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The list holds rent@carmacars.ca, and verify-admin@carmacars.ca, the automated test account the site&#39;s nightly checks sign in with.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Below it: everyone who holds the Admin role now. Each must be on the list; the database refuses the Admin role to any other address.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change the list only if the business&#39;s Admin address changes.</div></li></ol></div></section><section class="gd-task" id="people-and-access-staff-scorecards" data-gd-task><h2 class="gd-h2">Staff scorecards</h2><p class="gd-p">See how each assistant is doing against the targets.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On a staff member&#39;s row in Staff and roles, press <b class="gd-ui">Scorecard</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">By week shows each measure (for example quote sent within 15 minutes) and the result for each week.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A task meets its target when it is done by its due time. Daily checks count when done by 9:00 and 18:00.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/scorecard</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/350"><img src="/guides/img/va-sales-05-scorecard-desktop-956a5a9e.jpg" alt="" loading="lazy" decoding="async" width="1230" height="350"><span class="gd-pin" style="left:21.1%;top:42.9%" aria-hidden="true">2</span></div></div></figure></div></section>');
select app.guide_release_section('admin', 'requests-offers-and-bookings', 'chapter', 'people-and-access', 'Every booking starts as a request. You check it, adjust it and send the offer. After that, the booking page holds the money, documents, changes and history.

## The request queue

Open **Requests**. The oldest waiting request is at the top.

1. Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.
2. Waiting shows how long the renter has waited. Open a booking number to answer it.

![](/guides/img/admin-02-requests-desktop-6521282d.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/requests; pins: 1 18.5 21.2, 2 25.3 31.7")

## Answer a request with an offer

1. The Review and offer tab shows the request as the renter sent it.
2. Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.
3. Price on the right updates as you change things.
4. Add a message, choose how long the offer stays open, then press **Send the offer**.

![](/guides/img/admin-03-booking-review-desktop-84570463.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/bookings/CC-10020?tab=review; pins: 1 21.7 16.4, 2 20.0 45.4, 3 65.0 45.4, 4 96.5 98.8")

5. Changed fields but not ready to send? Press **Save changes**. The panel "The offer as the renter sees it" shows the result.
6. Can''t do it? Press **Decline** and fill in Reason and any alternative.
7. Need an answer first? Press **Ask the renter** to send a question.

![](/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg "desktop; size: 620 810; address: carmacars.ca/admin/bookings/CC-10020?tab=review; pins: 5 91.9 33.6")

> Tip: After the offer is out: **Withdraw to edit** takes it back, **Send again, later expiry** gives the renter more time, and **Renter approved by phone** records a yes given on a call.

## A booking

Open Bookings, then a booking number.

1. Tabs: Overview, Money, Changes, History, and Drivers and documents.
2. Overview shows the trip, the renter, what is still missing for the handover, and the price.
3. Open tasks for this booking, with the queue and the due time.
4. Top right: **Stop blocking the calendar**, **Cancel for the renter** and **Cancel by CarmaCars**.

![](/guides/img/admin-04-booking-desktop-b56b668a.jpg "desktop; size: 1440 960; address: carmacars.ca/admin/bookings/CC-10021; pins: 1 20.1 24.0, 2 34.7 58.3, 3 20.1 72.9, 4 90.3 18.3")

## Propose a change to a confirmed booking

The renter gets an email and answers on their booking. The calendar moves only when they accept.

1. Open the booking''s Changes tab. Under Propose a change, set the new pickup, return or car.
2. To price it by hand, type a New rental charge before tax. Leave it empty to use the car''s rates.
3. Write the Reason, for the renter. They read it.
4. Press **Preview the price**, then **Send to the renter**.

![](/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg "desktop; size: 1230 530; address: carmacars.ca/admin/bookings/CC-10021?tab=changes; pins: 1 12.9 15.3, 2 35.0 30.6, 3 49.8 59.1, 4 30.9 73.2")

> Tip: The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.
', 'Requests, offers and bookings', 'Answer a request with an offer, run a booking, and propose a change.',
  'Every booking starts as a request. You check it, adjust it and send the offer. After that, the booking page holds the money, documents, changes and history.

## The request queue

Open **Bookings** > **Requests**. The oldest waiting request is at the top.

1. Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.
2. Waiting shows how long the renter has waited. Open a booking number to answer it.

![](/guides/img/admin-02-requests-desktop-6521282d.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/requests; pins: 1 18.5 21.2, 2 25.3 31.7")

## Answer a request with an offer

1. The Review and offer tab shows the request as the renter sent it.
2. Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.
3. Price on the right updates as you change things.
4. Add a message, choose how long the offer stays open, then press **Send the offer**.

![](/guides/img/admin-03-booking-review-desktop-84570463.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 1 21.7 16.4, 2 20.0 45.4, 3 65.0 45.4, 4 96.5 98.8")

5. Changed fields but not ready to send? Press **Save changes**. The panel "The offer as the renter sees it" shows the result.
6. Can''t do it? Press **Decline** and fill in Reason and any alternative.
7. Need an answer first? Press **Ask the renter** to send a question.

![](/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg "desktop; size: 620 810; address: carmacars.ca/admin/bookings/CC-10056?tab=review; pins: 5 91.9 33.6")

> Tip: After the offer is out: **Withdraw to edit** takes it back, **Send again, later expiry** gives the renter more time, and **Renter approved by phone** records a yes given on a call.

## A booking

Open **Bookings** > **Bookings**, then a booking number. Or type the number in the search box.

1. Tabs: Overview, Money, Changes, History, and Drivers and documents.
2. Overview shows the trip, the renter, what is still missing for the handover, and the price.
3. Open tasks for this booking, with the queue and the due time.
4. Top right: **Stop blocking the calendar**, **Cancel for the renter** and **Cancel by CarmaCars**.

![](/guides/img/admin-04-booking-desktop-b56b668a.jpg "desktop; size: 1440 960; address: carmacars.ca/admin/bookings/CC-10057; pins: 1 20.1 24.0, 2 34.7 58.3, 3 20.1 72.9, 4 90.3 18.3")

## Propose a change to a confirmed booking

The renter gets an email and answers on their booking. The calendar moves only when they accept.

1. Open the booking''s Changes tab. Under Propose a change, set the new pickup, return or car.
2. To price it by hand, type a New rental charge before tax. Leave it empty to use the car''s rates.
3. Write the Reason, for the renter. They read it.
4. Press **Preview the price**, then **Send to the renter**.

![](/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg "desktop; size: 1230 530; address: carmacars.ca/admin/bookings/CC-10057?tab=changes; pins: 1 12.9 15.3, 2 35.0 30.6, 3 49.8 59.1, 4 30.9 73.2")

> Tip: The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.
',
  '<p class="gd-p">Every booking starts as a request. You check it, adjust it and send the offer. After that, the booking page holds the money, documents, changes and history.</p><section class="gd-task" id="requests-offers-and-bookings-the-request-queue" data-gd-task><h2 class="gd-h2">The request queue</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Requests</b>. The oldest waiting request is at the top.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Waiting shows how long the renter has waited. Open a booking number to answer it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/820"><img src="/guides/img/admin-02-requests-desktop-6521282d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="820"><span class="gd-pin" style="left:18.5%;top:21.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.3%;top:31.7%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-answer-a-request-with-an-offer" data-gd-task><h2 class="gd-h2">Answer a request with an offer</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The Review and offer tab shows the request as the renter sent it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Price on the right updates as you change things.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a message, choose how long the offer stays open, then press <b class="gd-ui">Send the offer</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1060"><img src="/guides/img/admin-03-booking-review-desktop-84570463.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1060"><span class="gd-pin" style="left:21.7%;top:16.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:20%;top:45.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:65%;top:45.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:96.5%;top:98.8%" aria-hidden="true">4</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="5"><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Changed fields but not ready to send? Press <b class="gd-ui">Save changes</b>. The panel &quot;The offer as the renter sees it&quot; shows the result.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Can&#39;t do it? Press <b class="gd-ui">Decline</b> and fill in Reason and any alternative.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Need an answer first? Press <b class="gd-ui">Ask the renter</b> to send a question.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:620/810"><img src="/guides/img/admin-03-booking-review-desktop-1139f8f9.jpg" alt="" loading="lazy" decoding="async" width="620" height="810"><span class="gd-pin" style="left:91.9%;top:33.6%" aria-hidden="true">5</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>After the offer is out: <b class="gd-ui">Withdraw to edit</b> takes it back, <b class="gd-ui">Send again, later expiry</b> gives the renter more time, and <b class="gd-ui">Renter approved by phone</b> records a yes given on a call.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-a-booking" data-gd-task><h2 class="gd-h2">A booking</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Bookings</b>, then a booking number. Or type the number in the search box.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Tabs: Overview, Money, Changes, History, and Drivers and documents.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Overview shows the trip, the renter, what is still missing for the handover, and the price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open tasks for this booking, with the queue and the due time.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Top right: <b class="gd-ui">Stop blocking the calendar</b>, <b class="gd-ui">Cancel for the renter</b> and <b class="gd-ui">Cancel by CarmaCars</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10057</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/960"><img src="/guides/img/admin-04-booking-desktop-b56b668a.jpg" alt="" loading="lazy" decoding="async" width="1440" height="960"><span class="gd-pin" style="left:20.1%;top:24%" aria-hidden="true">1</span><span class="gd-pin" style="left:34.7%;top:58.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:20.1%;top:72.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:90.3%;top:18.3%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-propose-a-change-to-a-confirmed-booking" data-gd-task><h2 class="gd-h2">Propose a change to a confirmed booking</h2><p class="gd-p">The renter gets an email and answers on their booking. The calendar moves only when they accept.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking&#39;s Changes tab. Under Propose a change, set the new pickup, return or car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To price it by hand, type a New rental charge before tax. Leave it empty to use the car&#39;s rates.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Write the Reason, for the renter. They read it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Preview the price</b>, then <b class="gd-ui">Send to the renter</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10057?tab=changes</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/530"><img src="/guides/img/admin-05-booking-changes-desktop-0b06af9a.jpg" alt="" loading="lazy" decoding="async" width="1230" height="530"><span class="gd-pin" style="left:12.9%;top:15.3%" aria-hidden="true">1</span><span class="gd-pin" style="left:35%;top:30.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:49.8%;top:59.1%" aria-hidden="true">3</span><span class="gd-pin" style="left:30.9%;top:73.2%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.</div></aside></section>');
select app.guide_release_section('admin', 'calendars', 'chapter', 'requests-offers-and-bookings', 'The master calendar shows every car, booking, request and block. Each car also has its own calendar and turnaround time.

## The master calendar

1. Move through time with the arrows and **Today**, or pick a date.
2. Choose the range: **Today**, **Week**, **2 weeks** or **Month**. **Agenda** shows a list instead.
3. The legend: confirmed, on rent, request, offer, not blocking, block and Turo.
4. Each row is a car. Bars are bookings and blocks; the red line is now.

![](/guides/img/admin-06-calendar-desktop-fed75400.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/calendar; pins: 1 23.4 17.9, 2 45.3 17.9, 3 32.3 23.9, 4 66.6 33.0")

## Move a booking, add or remove a block

1. To move a booking, drag its bar to the new car or time, then press **Confirm the move**.
2. To block a car, double-click its row where the block starts, then press **Create the block**. **New block** at the top does the same.
3. To remove a block, open it and press **Remove the block**.

> Tip: After every confirmed trip a cleaning block holds the car for its turnaround time. It follows changes and extensions and goes away with a cancellation. Remove it from the side panel if the car is ready sooner; that time is then free.

## A car''s own calendar

›*the car›*Calendar

1. The Calendar tab shows only this car, with its bookings and blocks.
2. Turnaround between trips on this car shows the time used. Press **Change** to give this car its own time.

![](/guides/img/admin-07-vehicle-calendar-desktop-98586ca8.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/vehicles/e6258c8d-17af-427d-a5e6-8828343a416d?tab=calendar; pins: 1 42.1 31.1, 2 51.4 40.7")
', 'Calendars', 'The master calendar, moving bookings, blocks, cleaning time and a car''s calendar.',
  'The master calendar shows every car, booking, request and block. Each car also has its own calendar and turnaround time.

## The master calendar

1. Move through time with the arrows and **Today**, or pick a date.
2. Choose the range: **Today**, **Week**, **2 weeks** or **Month**. **Agenda** shows a list instead.
3. The legend: confirmed, on rent, request, offer, not blocking, block and Turo.
4. Each row is a car. Bars are bookings and blocks; the red line is now.

![](/guides/img/admin-06-calendar-desktop-fed75400.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/calendar; pins: 1 23.4 17.9, 2 45.3 17.9, 3 32.3 23.9, 4 66.6 33.0")

## Move a booking, add or remove a block

1. To move a booking, drag its bar to the new car or time, then press **Confirm the move**.
2. To block a car, double-click its row where the block starts, then press **Create the block**. **New block** at the top does the same.
3. To remove a block, open it and press **Remove the block**.

> Tip: After every confirmed trip a cleaning block holds the car for its turnaround time. It follows changes and extensions and goes away with a cancellation. Remove it from the side panel if the car is ready sooner; that time is then free.

## A car''s own calendar

**Cars** > **Vehicles**, then the car, then its Calendar tab.

1. The Calendar tab shows only this car, with its bookings and blocks.
2. Turnaround between trips on this car shows the time used. Press **Change** to give this car its own time.

![](/guides/img/admin-07-vehicle-calendar-desktop-98586ca8.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/vehicles/32d37609-00ed-4d39-ae12-9284421fb969?tab=calendar; pins: 1 42.1 31.1, 2 51.4 40.7")
',
  '<p class="gd-p">The master calendar shows every car, booking, request and block. Each car also has its own calendar and turnaround time.</p><section class="gd-task" id="calendars-the-master-calendar" data-gd-task><h2 class="gd-h2">The master calendar</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Move through time with the arrows and <b class="gd-ui">Today</b>, or pick a date.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the range: <b class="gd-ui">Today</b>, <b class="gd-ui">Week</b>, <b class="gd-ui">2 weeks</b> or <b class="gd-ui">Month</b>. <b class="gd-ui">Agenda</b> shows a list instead.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The legend: confirmed, on rent, request, offer, not blocking, block and Turo.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Each row is a car. Bars are bookings and blocks; the red line is now.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/calendar</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/admin-06-calendar-desktop-fed75400.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:23.4%;top:17.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:45.3%;top:17.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:32.3%;top:23.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:66.6%;top:33%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="calendars-move-a-booking-add-or-remove-a-block" data-gd-task><h2 class="gd-h2">Move a booking, add or remove a block</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">To move a booking, drag its bar to the new car or time, then press <b class="gd-ui">Confirm the move</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To block a car, double-click its row where the block starts, then press <b class="gd-ui">Create the block</b>. <b class="gd-ui">New block</b> at the top does the same.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To remove a block, open it and press <b class="gd-ui">Remove the block</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>After every confirmed trip a cleaning block holds the car for its turnaround time. It follows changes and extensions and goes away with a cancellation. Remove it from the side panel if the car is ready sooner; that time is then free.</div></aside></section><section class="gd-task" id="calendars-a-car-s-own-calendar" data-gd-task><h2 class="gd-h2">A car&#39;s own calendar</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, then the car, then its Calendar tab.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The Calendar tab shows only this car, with its bookings and blocks.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Turnaround between trips on this car shows the time used. Press <b class="gd-ui">Change</b> to give this car its own time.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/vehicles/32d37609-00ed-4d39-ae12-9284421fb969?tab=calendar</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/560"><img src="/guides/img/admin-07-vehicle-calendar-desktop-98586ca8.jpg" alt="" loading="lazy" decoding="async" width="1440" height="560"><span class="gd-pin" style="left:42.1%;top:31.1%" aria-hidden="true">1</span><span class="gd-pin" style="left:51.4%;top:40.7%" aria-hidden="true">2</span></div></div></figure></div></section>');
select app.guide_release_section('admin', 'fleet-and-listings', 'chapter', 'calendars', 'Vehicles is the fleet. Listings is the pipeline that turns a car into a page on carmacars.ca: photos, copy, a duplicate check and a covered plate on every public photo.

## Vehicles

1. Filter by status and mode. Each row shows the plate, class, owner, mode, status, listing and daily rate.
2. Search by plate, model or owner. **Bulk rate change** changes rates of many cars at once.
3. Open a car for its tabs: Overview, Rates, Fees and coverage, Calendar, Listing, and Owner, documents, tracker.

![](/guides/img/admin-08-vehicles-desktop-46461f49.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/vehicles; pins: 1 18.5 19.3, 2 83.5 12.9, 3 73.6 38.9")

> Coming soon: The Tracker card on a car says "Coming soon": live location, the remote immobilize request and mileage from the tracker need the tracker company''s connection first.

## The listing pipeline

Open **Listings**. A draft waiting for review shows Needs review.

1. Each row shows the car, plate, state, photos and the pipeline''s progress.
2. Press **Start a listing** to begin one for a car that has none.
3. Open a car to review it.

![](/guides/img/admin-09-listings-desktop-970819b6.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/listings; pins: 1 53.5 37.0, 2 87.2 21.1, 3 32.6 37.0")

## Review a listing

1. Pipeline shows each step done, such as photo sizes, copy draft and backgrounds.
2. Similar cars on file lists possible duplicates. Press **Not a duplicate** or **Same car**. An open flag stops publishing.
3. Check the copy: headline, description, features, questions, search title and description.
4. Under Photos, each public photo shows its plate state: Plate not checked, Plate covered or No plate visible.

![](/guides/img/admin-10-listing-review-desktop-352745fd.jpg "desktop; size: 1440 1100; address: carmacars.ca/admin/listings/18a7d87f-4140-49e3-aa3d-fcd282b3ef2c; pins: 1 20.6 16.6, 2 86.1 47.5, 3 19.9 106.8, 4 74.9 106.8")

## Cover the licence plate

On each public photo press **Cover the plate**. The editor opens.

1. The editor suggests a box over the plate. Check it. **Suggest the plate** asks again.
2. Drag over a plate to draw a box. Drag a box to move it, or its corner to resize it.
3. Under Cover the plate with, choose **A CarmaCars plate**, **Pixelation** or **Blur**.
4. Press **Save the covered photo**. **Clear the boxes** starts over.
5. No plate in the shot? Press **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-desktop-4219ad93.jpg "desktop; size: 690 703; address: carmacars.ca/admin/listings/18a7d87f-4140-49e3-aa3d-fcd282b3ef2c; pins: 1 42.5 83.8, 2 49.6 29.9, 3 4.3 77.4, 4 15.5 83.8, 5 18.1 91.2")

> Tip: The covered photo replaces the public one; the original is kept privately. Keyboard: N adds a box, the arrows move it, Shift and the arrows resize it, Delete removes it.

## Publish

1. When every public photo is covered or marked, press **Approve and publish**.
2. Or press **Approve, publish later**, or **Send back** with what to fix.

> Watch out: Publishing waits for a plate decision on every public photo ("Cover the licence plate or mark it not visible on every public photo first"). Listings already live show "Plate not checked" until someone checks them.
', 'Fleet and listings', 'Vehicles, the listing pipeline, similar cars and covering licence plates.',
  'Vehicles is the fleet. Listings is the pipeline that turns a car into a page on carmacars.ca: photos, copy, a duplicate check and a covered plate on every public photo.

## Vehicles

**Cars** > **Vehicles**

1. Filter by status and mode. Each row shows the plate, class, owner, mode, status, listing and daily rate.
2. Search by plate, model or owner. **Cars** > **Rates for many cars** changes the rates of many cars at once.
3. Open a car for its tabs: Overview, Rates, Fees and coverage, Calendar, Listing, and Owner, documents, tracker.

![](/guides/img/admin-08-vehicles-desktop-46461f49.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/vehicles; pins: 1 18.5 19.3, 2 83.5 12.9, 3 73.6 38.9")

> Coming soon: The Tracker card on a car says "Coming soon": live location, the remote immobilize request and mileage from the tracker need the tracker company''s connection first.

## The listing pipeline

Open **Cars** > **Listings**. A draft waiting for review shows Needs review.

1. Each row shows the car, plate, state, photos and the pipeline''s progress.
2. Press **Start a listing** to begin one for a car that has none.
3. Open a car to review it.

![](/guides/img/admin-09-listings-desktop-970819b6.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/listings; pins: 1 53.5 37.0, 2 87.2 21.1, 3 32.6 37.0")

## Review a listing

1. Pipeline shows each step done, such as photo sizes, copy draft and backgrounds.
2. Similar cars on file lists possible duplicates. Press **Not a duplicate** or **Same car**. An open flag stops publishing.
3. Check the copy: headline, description, features, questions, search title and description.
4. Under Photos, each public photo shows its plate state: Plate not checked, Plate covered or No plate visible.

![](/guides/img/admin-10-listing-review-desktop-352745fd.jpg "desktop; size: 1440 1100; address: carmacars.ca/admin/listings/7e43d38d-32bb-4666-a742-81813c3b7671; pins: 1 20.6 16.6, 2 86.1 47.5, 3 19.9 106.8, 4 74.9 106.8")

## Cover the licence plate

On each public photo press **Cover the plate**. The editor opens.

1. The editor suggests a box over the plate. Check it. **Suggest the plate** asks again.
2. Drag over a plate to draw a box. Drag a box to move it, or its corner to resize it.
3. Under Cover the plate with, choose **A CarmaCars plate**, **Pixelation** or **Blur**.
4. Press **Save the covered photo**. **Clear the boxes** starts over.
5. No plate in the shot? Press **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-desktop-4219ad93.jpg "desktop; size: 690 703; address: carmacars.ca/admin/listings/7e43d38d-32bb-4666-a742-81813c3b7671; pins: 1 42.5 83.8, 2 49.6 29.9, 3 4.3 77.4, 4 15.5 83.8, 5 18.1 91.2")

> Tip: The covered photo replaces the public one; the original is kept privately. Keyboard: N adds a box, the arrows move it, Shift and the arrows resize it, Delete removes it.

## Publish

1. When every public photo is covered or marked, press **Approve and publish**.
2. Or press **Approve, publish later**, or **Send back** with what to fix.

> Watch out: Publishing waits for a plate decision on every public photo ("Cover the licence plate or mark it not visible on every public photo first"). Listings already live show "Plate not checked" until someone checks them.

## A listing without photos yet: sample photos

A car can be listed before its photos are taken. Until then the site shows a sample photo.

1. Submit the listing without photos. The listing copy is still written for you from the car''s details.
2. The car page and the car''s card show a sample photo, captioned "Sample photo", so renters know it is not this car. Staff see "Using sample photos" on the car and in Listings.
3. Publishing does not wait for a plate check: a sample photo has no plate.
4. Add the real photos when they are taken. Once real photos are approved they replace the sample at once; nothing else to do.

## Sample photos

**Settings** > **Sample photos**. The pictures a car shows until its real photos are in.

1. Every body type has a built-in picture (sedan, SUV, truck, van, coupe, hatchback, electric car).
2. Add your own: choose the Body type, and a Make and Model if the photo is of that exact model, pick the Photo, and press **Add the photo**.
3. The most specific photo wins: make and model, then make and body type, then body type. **Turn off** or **Delete** a photo you no longer want.
4. Cars using sample photos lists the cars still waiting for real photos. It is also a line on To do.

![](/guides/img/admin-36-sample-photos-desktop-55c64070.jpg "desktop; size: 1440 812; address: carmacars.ca/admin/settings/sample-photos; pins: 4 26.8 28.9")
',
  '<p class="gd-p">Vehicles is the fleet. Listings is the pipeline that turns a car into a page on carmacars.ca: photos, copy, a duplicate check and a covered plate on every public photo.</p><section class="gd-task" id="fleet-and-listings-vehicles" data-gd-task><h2 class="gd-h2">Vehicles</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b></p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Filter by status and mode. Each row shows the plate, class, owner, mode, status, listing and daily rate.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Search by plate, model or owner. <b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Rates for many cars</b> changes the rates of many cars at once.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open a car for its tabs: Overview, Rates, Fees and coverage, Calendar, Listing, and Owner, documents, tracker.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/vehicles</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-08-vehicles-desktop-46461f49.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:18.5%;top:19.3%" aria-hidden="true">1</span><span class="gd-pin" style="left:83.5%;top:12.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:73.6%;top:38.9%" aria-hidden="true">3</span></div></div></figure></div><aside class="gd-box"><div>Coming soon: The Tracker card on a car says &quot;Coming soon&quot;: live location, the remote immobilize request and mileage from the tracker need the tracker company&#39;s connection first.</div></aside></section><section class="gd-task" id="fleet-and-listings-the-listing-pipeline" data-gd-task><h2 class="gd-h2">The listing pipeline</h2><p class="gd-p">Open <b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Listings</b>. A draft waiting for review shows Needs review.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each row shows the car, plate, state, photos and the pipeline&#39;s progress.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Start a listing</b> to begin one for a car that has none.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open a car to review it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/listings</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/560"><img src="/guides/img/admin-09-listings-desktop-970819b6.jpg" alt="" loading="lazy" decoding="async" width="1440" height="560"><span class="gd-pin" style="left:53.5%;top:37%" aria-hidden="true">1</span><span class="gd-pin" style="left:87.2%;top:21.1%" aria-hidden="true">2</span><span class="gd-pin" style="left:32.6%;top:37%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-and-listings-review-a-listing" data-gd-task><h2 class="gd-h2">Review a listing</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Pipeline shows each step done, such as photo sizes, copy draft and backgrounds.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Similar cars on file lists possible duplicates. Press <b class="gd-ui">Not a duplicate</b> or <b class="gd-ui">Same car</b>. An open flag stops publishing.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check the copy: headline, description, features, questions, search title and description.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Under Photos, each public photo shows its plate state: Plate not checked, Plate covered or No plate visible.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/listings/7e43d38d-32bb-4666-a742-81813c3b7671</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1100"><img src="/guides/img/admin-10-listing-review-desktop-352745fd.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1100"><span class="gd-pin" style="left:20.6%;top:16.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:86.1%;top:47.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:19.9%;top:100%" aria-hidden="true">3</span><span class="gd-pin" style="left:74.9%;top:100%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="fleet-and-listings-cover-the-licence-plate" data-gd-task><h2 class="gd-h2">Cover the licence plate</h2><p class="gd-p">On each public photo press <b class="gd-ui">Cover the plate</b>. The editor opens.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The editor suggests a box over the plate. Check it. <b class="gd-ui">Suggest the plate</b> asks again.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Drag over a plate to draw a box. Drag a box to move it, or its corner to resize it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Under Cover the plate with, choose <b class="gd-ui">A CarmaCars plate</b>, <b class="gd-ui">Pixelation</b> or <b class="gd-ui">Blur</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Save the covered photo</b>. <b class="gd-ui">Clear the boxes</b> starts over.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">No plate in the shot? Press <b class="gd-ui">No plate visible on this photo</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/listings/7e43d38d-32bb-4666-a742-81813c3b7671</span></div><div class="gd-imgwrap" style="aspect-ratio:690/703"><img src="/guides/img/admin-11-plate-editor-desktop-4219ad93.jpg" alt="" loading="lazy" decoding="async" width="690" height="703"><span class="gd-pin" style="left:42.5%;top:83.8%" aria-hidden="true">1</span><span class="gd-pin" style="left:49.6%;top:29.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:4.3%;top:77.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:15.5%;top:83.8%" aria-hidden="true">4</span><span class="gd-pin" style="left:18.1%;top:91.2%" aria-hidden="true">5</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The covered photo replaces the public one; the original is kept privately. Keyboard: N adds a box, the arrows move it, Shift and the arrows resize it, Delete removes it.</div></aside></section><section class="gd-task" id="fleet-and-listings-publish" data-gd-task><h2 class="gd-h2">Publish</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When every public photo is covered or marked, press <b class="gd-ui">Approve and publish</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Or press <b class="gd-ui">Approve, publish later</b>, or <b class="gd-ui">Send back</b> with what to fix.</div></li></ol></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Publishing waits for a plate decision on every public photo (&quot;Cover the licence plate or mark it not visible on every public photo first&quot;). Listings already live show &quot;Plate not checked&quot; until someone checks them.</div></aside></section><section class="gd-task" id="fleet-and-listings-a-listing-without-photos-yet-sample-photos" data-gd-task><h2 class="gd-h2">A listing without photos yet: sample photos</h2><p class="gd-p">A car can be listed before its photos are taken. Until then the site shows a sample photo.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Submit the listing without photos. The listing copy is still written for you from the car&#39;s details.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car page and the car&#39;s card show a sample photo, captioned &quot;Sample photo&quot;, so renters know it is not this car. Staff see &quot;Using sample photos&quot; on the car and in Listings.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Publishing does not wait for a plate check: a sample photo has no plate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add the real photos when they are taken. Once real photos are approved they replace the sample at once; nothing else to do.</div></li></ol></div></section><section class="gd-task" id="fleet-and-listings-sample-photos" data-gd-task><h2 class="gd-h2">Sample photos</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Sample photos</b>. The pictures a car shows until its real photos are in.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every body type has a built-in picture (sedan, SUV, truck, van, coupe, hatchback, electric car).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Add your own: choose the Body type, and a Make and Model if the photo is of that exact model, pick the Photo, and press <b class="gd-ui">Add the photo</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The most specific photo wins: make and model, then make and body type, then body type. <b class="gd-ui">Turn off</b> or <b class="gd-ui">Delete</b> a photo you no longer want.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Cars using sample photos lists the cars still waiting for real photos. It is also a line on To do.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/sample-photos</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/812"><img src="/guides/img/admin-36-sample-photos-desktop-55c64070.jpg" alt="" loading="lazy" decoding="async" width="1440" height="812"><span class="gd-pin" style="left:26.8%;top:28.9%" aria-hidden="true">4</span></div></div></figure></div></section>');
select app.guide_release_section('admin', 'partners-company-cars-and-rentals-added-by-hand', 'chapter', 'fleet-and-listings', 'A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.

## Add a car

›*Add a car. First choose who supplies it.

1. **A program owner''s car**: choose the owner. The car starts its onboarding (terms, agreements, registry) as if the owner had applied.
2. **CarmaCars-owned (company fleet)**: no owner. All of its revenue is CarmaCars'' and it shows in the company statement as company fleet.
3. **A partner rental company''s car**: choose the partner. Leave the commission empty to use the partner''s, or type one for this car.
4. Type the VIN, the plate and the details, and the rates if you have them. Press **Add the car**.

> Tip: The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.

On a car''s page, **Who supplies the car** shows the supplier and the commission, and changes them. Vehicles filters by supply type.

## Partners

›*Partners. Partner rental companies whose cars we rent out on commission.

1. Press **Add a partner**: business and legal name, contacts, HST number, commission and insurance with its expiry date.
2. Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Tasks gets a reminder (Program settings sets how many days before).
3. Banking (Admins only): **Save the payout account** for the account we pay the partner into. The account number is stored encrypted. Press **Verify** once checked.
4. Portal: **Invite to the owner portal** gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.
5. Signed on paper? Press **Print the partner agreement**, then record the signed scan under Record a paper signature.

> Watch out: The partner agreement is a draft for lawyer review. Use it only once it is approved.

## Add a rental by hand

›*Add a rental. For phone, walk-in, Turo, partner and insurer bookings.

1. Choose the car and the dates. The check shows clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.
2. Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.
3. Check the price: the car''s rates, extras, coverage and deposit. An Admin may set the price by hand; assistants use the rate sheet and the discounts allowed.
4. Choose Where it came from and how it is paid: **Paid another way**, **Send a payment link**, **Charge the saved card** or **Unpaid: invoice later**.
5. Press **Check the calendar and the price**. Tick **Do not email the renter** if they should not get the confirmation. Press **Add the rental**.

> Tip: The rental is confirmed and on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. On the booking, **Verified in person** records a licence checked at the counter. A past rental is recorded as completed.

## Retire or delete a car

›*the car, then **Retire or delete**.

1. **Retire this car** takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. **Restore** brings it back.
2. **Delete this car** removes a car added by mistake, with its photos. Only a car with nothing tied to money (no booking, payment, statement, toll or damage). Type the plate or the name to confirm.
3. ›*Sample cars, then **Delete all sample cars**, deletes every sample car that meets the rule at once. Type DELETE SAMPLE CARS to confirm; the ones kept show why.

## Tolls when two rentals overlap

Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.
', 'Partners, company cars and rentals added by hand', 'Add a car, partners, add a rental, retire or delete a car, sample cars and tolls with two rentals.',
  'A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.

## Add a car

**Cars** > **Vehicles**, then **Add a car**. First choose who supplies it.

1. **A program owner''s car**: choose the owner. The car starts its onboarding (terms, agreements, registry) as if the owner had applied.
2. **CarmaCars-owned (company fleet)**: no owner. All of its revenue is CarmaCars'' and it shows in the company statement as company fleet.
3. **A partner rental company''s car**: choose the partner. Leave the commission empty to use the partner''s, or type one for this car.
4. Type the VIN, the plate and the details, and the rates if you have them. Press **Add the car**.

> Tip: The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.

On a car''s page, **Who supplies the car** shows the supplier and the commission, and changes them. Vehicles filters by supply type.

## Partners

**Owners and partners** > **Partners**. Partner rental companies whose cars we rent out on commission.

1. Press **Add a partner**: business and legal name, contacts, HST number, commission and insurance with its expiry date.
2. Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Tasks gets a reminder (Program settings sets how many days before).
3. Banking (Admins only): **Save the payout account** for the account we pay the partner into. The account number is stored encrypted. Press **Verify** once checked.
4. Portal: **Invite to the owner portal** gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.
5. Signed on paper? Press **Print the partner agreement**, then record the signed scan under Record a paper signature.

## Add a rental by hand

**Bookings** > **Add a rental**. For phone, walk-in, Turo, partner and insurer bookings.

1. Choose the car and the dates. The check shows clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.
2. Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.
3. Check the price: the car''s rates, extras, coverage and deposit. An Admin may set the price by hand; assistants use the rate sheet and the discounts allowed.
4. Choose Where it came from and how it is paid: **Paid another way**, **Send a payment link**, **Charge the saved card when the renter signs** or **Unpaid: invoice later**.
5. Press **Check the calendar and the price**. Tick **Do not email the renter** if they should not get the confirmation. Press **Add the rental**.

> Tip: The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. On the booking, **Verified in person** records a licence checked at the counter. A past rental is recorded as completed.

## Retire or delete a car

**Cars** > **Retire or delete**, or the car''s own page.

1. **Retire this car** takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. **Restore** brings it back.
2. **Delete this car** removes a car added by mistake, with its photos. Only a car with nothing tied to money (no booking, payment, statement, toll or damage). Type the plate or the name to confirm.
3. On the same page, **Delete all sample cars** deletes every sample car that meets the rule at once. Type DELETE SAMPLE CARS to confirm; the ones kept show why.

## Tolls when two rentals overlap

Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.
',
  '<p class="gd-p">A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.</p><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-add-a-car" data-gd-task><h2 class="gd-h2">Add a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, then <b class="gd-ui">Add a car</b>. First choose who supplies it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">A program owner&#39;s car</b>: choose the owner. The car starts its onboarding (terms, agreements, registry) as if the owner had applied.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">CarmaCars-owned (company fleet)</b>: no owner. All of its revenue is CarmaCars&#39; and it shows in the company statement as company fleet.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">A partner rental company&#39;s car</b>: choose the partner. Leave the commission empty to use the partner&#39;s, or type one for this car.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Type the VIN, the plate and the details, and the rates if you have them. Press <b class="gd-ui">Add the car</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.</div></aside><p class="gd-p">On a car&#39;s page, <b class="gd-ui">Who supplies the car</b> shows the supplier and the commission, and changes them. Vehicles filters by supply type.</p></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-partners" data-gd-task><h2 class="gd-h2">Partners</h2><p class="gd-p"><b class="gd-ui">Owners and partners</b> &gt; <b class="gd-ui">Partners</b>. Partner rental companies whose cars we rent out on commission.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Add a partner</b>: business and legal name, contacts, HST number, commission and insurance with its expiry date.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Tasks gets a reminder (Program settings sets how many days before).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Banking (Admins only): <b class="gd-ui">Save the payout account</b> for the account we pay the partner into. The account number is stored encrypted. Press <b class="gd-ui">Verify</b> once checked.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Portal: <b class="gd-ui">Invite to the owner portal</b> gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Signed on paper? Press <b class="gd-ui">Print the partner agreement</b>, then record the signed scan under Record a paper signature.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-add-a-rental-by-hand" data-gd-task><h2 class="gd-h2">Add a rental by hand</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Add a rental</b>. For phone, walk-in, Turo, partner and insurer bookings.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose the car and the dates. The check shows clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check the price: the car&#39;s rates, extras, coverage and deposit. An Admin may set the price by hand; assistants use the rate sheet and the discounts allowed.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Choose Where it came from and how it is paid: <b class="gd-ui">Paid another way</b>, <b class="gd-ui">Send a payment link</b>, <b class="gd-ui">Charge the saved card when the renter signs</b> or <b class="gd-ui">Unpaid: invoice later</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Check the calendar and the price</b>. Tick <b class="gd-ui">Do not email the renter</b> if they should not get the confirmation. Press <b class="gd-ui">Add the rental</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. On the booking, <b class="gd-ui">Verified in person</b> records a licence checked at the counter. A past rental is recorded as completed.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-retire-or-delete-a-car" data-gd-task><h2 class="gd-h2">Retire or delete a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Retire or delete</b>, or the car&#39;s own page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Retire this car</b> takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. <b class="gd-ui">Restore</b> brings it back.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Delete this car</b> removes a car added by mistake, with its photos. Only a car with nothing tied to money (no booking, payment, statement, toll or damage). Type the plate or the name to confirm.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the same page, <b class="gd-ui">Delete all sample cars</b> deletes every sample car that meets the rule at once. Type DELETE SAMPLE CARS to confirm; the ones kept show why.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-tolls-when-two-rentals-overlap" data-gd-task><h2 class="gd-h2">Tolls when two rentals overlap</h2><p class="gd-p">Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.</p></section>');
select app.guide_release_section('admin', 'owners-and-onboarding', 'chapter', 'partners-company-cars-and-rentals-added-by-hand', 'Owners apply on the site. You approve them, set their terms, and check their forms. Their page shows everything about them in one place.

## Owner applications

›*Owners

1. Each owner shows their application, how many cars, and where onboarding stands.
2. **View as (owner portal)** shows their portal. **Send password link** helps them sign in.
3. Invite an owner on file: fill in Name and Email under Invite an owner, then press **Send invitation**.

![](/guides/img/admin-12-owners-desktop-3a54d505.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/owners; pins: 1 41.0 42.9, 2 37.4 49.3, 3 77.4 82.5")

## Approve an application and set terms

1. Open the application and press **Approve and set terms** (or **Set terms (standard grid)**).
2. The owner signs everything at once in their portal (Check and sign: the agreements, schedules, Forms A and B and the official forms that are ready, with one signature) and pays the upfront invoice.
3. Paid another way? On the invoice, press **Record payment** (see Paid and signed, below).

## An owner''s page

Open an owner from Owners. The details are in the right-hand column.

1. Upfront invoices: issue the first and last month''s insurance fee for each car whose terms are set.
2. Owner: address, sign-in, agreements, and what is still missing for the registry forms.
3. Statements and payouts for this owner.
4. Forms C and D, with a link to the review queue.
5. Further down: **View as (owner portal)**, **Send password link** and **Send a sign-in link to the owner portal**.

![](/guides/img/admin-13-owner-desktop-819a9f8b.jpg "desktop; size: 410 1030; address: carmacars.ca/admin/owners/628a3315-6335-4e85-a396-f180565d5af5; pins: 1 24.6 4.4, 2 16.1 32.9, 3 31.5 73.2, 4 21.2 98.1")

## Paid and signed

›*Owners, then **Paid and signed**. What each owner still has to pay or sign, and how each item was done.

1. Each owner shows how many items are open and how many are done. Owners with nothing left are hidden; press Show every owner to see them.
2. Open **Checklist and quick actions**. Each line says Signed in the portal, Signed on paper, Paid by e-Transfer, Not signed, and so on.
3. Paid by e-Transfer, cheque, cash or bank transfer? Press **Record payment**. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance, or type less for a partial payment. Add a photo of the cheque or a screenshot if you have one.
4. Signed on paper? Press **Record paper signature**. Choose the Document, check Signed by and Date signed, add the witnesses where the form needs them, and upload the scan of every signed page.
5. The same checklist sits at the top of each owner''s page.

A recorded payment marks the invoice paid (or partly paid), stops the automatic debit for that amount, sends the owner a receipt, and shows "Paid by e-Transfer on " in their portal. A paper signature counts as signed everywhere: the checklist, onboarding and the owner portal. The scan is kept privately with the owner''s documents.

> Watch out: Recorded the wrong thing, or a cheque bounced? Press **Void** beside it and give the reason. The invoice owes that amount again and the owner is told; a voided signature makes the item open again. Only an Admin can void.

## Forms C and D

›*Owner forms. Owners print them filled in, sign in front of witnesses and send a photo of each page from their phone.

1. Each row shows the owner, the form, the witnesses and when it was uploaded.
2. Press Open to read the photo or scan. Check each marked spot is signed or initialled.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/admin-22-owner-forms-desktop-c20ad300.jpg "desktop; size: 1440 470; address: carmacars.ca/admin/owner-forms; pins: 1 29.2 52.3, 2 57.6 52.3, 3 76.7 52.3")
', 'Owners and onboarding', 'Applications, an owner''s page, paid and signed, and Forms C and D.',
  'Owners apply on the site with List your car. Every application waits for you in one place, Applications: approve it, ask the owner for something, or decline it. Approved owners sign and pay in their portal.

## Applications

**Owners and partners** > **Applications**. Every owner application, newest first.

1. The chips filter by status: New, Waiting on owner, Approved, Declined, or All. New applications also show on To do.
2. Each row shows the application number, the owner, the car, how many of the four checks are done, and when they applied.
3. Open an application to decide.

![](/guides/img/admin-33-applications-desktop-152f9e34.jpg "desktop; size: 1440 640; address: carmacars.ca/admin/applications; pins: 1 36.8 39.7, 2 48.6 53.1, 3 19.8 53.1")

## Decide on an application

One page holds everything: the owner, the car, the uploads, the four checks and the notes.

1. Check the driver''s licence, the ownership, the insurance and the lender or lessor. Mark each one Checked, fine, Problem or Not needed.
2. Press **Approve**. The owner becomes active, the car gets its terms from the standard grid, the first and last month''s invoices are issued, and the owner gets an email to sign and pay in the owner portal.
3. Missing something? Press **Ask for something**, tick what you need (for example the ownership permit or the insurance slip), add a message if you like, and press **Send to the owner**. The owner gets an email and a task in their portal; the application shows Waiting on owner until they answer.
4. Not a fit? Press **Decline**, write the Reason the owner reads, and press **Decline the application**. The owner is emailed for each car.

![](/guides/img/admin-34-application-desktop-98b64f92.jpg "desktop; size: 1440 812; address: carmacars.ca/admin/applications/166e487a-11a1-4433-b1ca-8c2bc14bf5ca; pins: 1 72.9 67.1, 2 73.9 42.9, 3 84.7 42.9, 4 72.9 49.6")

> Tip: Notes on the page are for staff only: **Add note** keeps a line on the record. When the owner answers a request, their answer is in the notes and the application is New again.

## Owners

**Owners and partners** > **Owners**. Every owner, with their cars and where onboarding stands.

1. Each owner shows their application, how many cars, and where onboarding stands.
2. **View as (owner portal)** shows their portal. **Send password link** helps them sign in.
3. Invite an owner on file: fill in Name and Email under Invite an owner, then press **Send invitation**.

![](/guides/img/admin-12-owners-desktop-3a54d505.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/owners; pins: 1 41.0 42.9, 2 37.4 49.3, 3 77.4 82.5")

The owner signs everything at once in their portal (Check and sign: the agreements, schedules, Forms A and B and the official forms that are ready). The confirmations to tick, then one signature: CarmaCars countersigns at the same moment, under the signing officer''s standing authorization. A car with a second owner on the ownership waits for that owner too: they get their own link by email and sign the same documents.

## An owner''s page

Open an owner from Owners. The details are in the right-hand column.

1. Upfront invoices: issue the first and last month''s insurance fee for each car whose terms are set.
2. Owner: address, sign-in, agreements, and what is still missing for the registry forms.
3. Statements and payouts for this owner.
4. Forms C and D, with a link to the review queue.
5. Further down: **View as (owner portal)**, **Send password link** and **Send a sign-in link to the owner portal**.

![](/guides/img/admin-13-owner-desktop-819a9f8b.jpg "desktop; size: 410 1030; address: carmacars.ca/admin/owners/9e367055-7780-4451-822a-d79d5b59a309; pins: 1 24.6 4.4, 2 16.1 32.9, 3 31.5 73.2, 4 21.2 98.1")

## Paid and signed

**Owners and partners** > **Paid and signed**. What each owner still has to pay or sign, and how each item was done.

1. Each owner shows how many items are open and how many are done. Owners with nothing left are hidden; press Show every owner to see them.
2. Open **Checklist and quick actions**. Each line says Signed in the portal, Signed on paper, Paid by e-Transfer, Not signed, and so on.
3. Paid by e-Transfer, cheque, cash or bank transfer? Press **Record payment**. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance, or type less for a partial payment. Add a photo of the cheque or a screenshot if you have one.
4. Signed on paper? Press **Record paper signature**. Choose the Document, check Signed by and Date signed, add the witnesses where the form needs them, and upload the scan of every signed page.
5. The same checklist sits at the top of each owner''s page.

A recorded payment marks the invoice paid (or partly paid), stops the automatic debit for that amount, sends the owner a receipt, and shows "Paid by e-Transfer on " in their portal. A paper signature counts as signed everywhere: the checklist, onboarding and the owner portal. The scan is kept privately with the owner''s documents.

> Watch out: Recorded the wrong thing, or a cheque bounced? Press **Void** beside it and give the reason. The invoice owes that amount again and the owner is told; a voided signature makes the item open again. Only an Admin can void.

## Forms C and D

**Owners and partners** > **Owner forms**. Form C is signed on screen in the owner portal, with the witness on the same screen. Form D (and Form C on paper, if the owner prefers) is printed, signed in front of witnesses, and sent as a photo of each page.

1. Each row shows the owner, the form, the witnesses and when it was uploaded.
2. Press Open to read the photo or scan. Check each marked spot is signed or initialled.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/admin-22-owner-forms-desktop-c20ad300.jpg "desktop; size: 1440 470; address: carmacars.ca/admin/owner-forms; pins: 1 29.2 52.3, 2 57.6 52.3, 3 76.7 52.3")
',
  '<p class="gd-p">Owners apply on the site with List your car. Every application waits for you in one place, Applications: approve it, ask the owner for something, or decline it. Approved owners sign and pay in their portal.</p><section class="gd-task" id="owners-and-onboarding-applications" data-gd-task><h2 class="gd-h2">Applications</h2><p class="gd-p"><b class="gd-ui">Owners and partners</b> &gt; <b class="gd-ui">Applications</b>. Every owner application, newest first.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The chips filter by status: New, Waiting on owner, Approved, Declined, or All. New applications also show on To do.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each row shows the application number, the owner, the car, how many of the four checks are done, and when they applied.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open an application to decide.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/applications</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/admin-33-applications-desktop-152f9e34.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:36.8%;top:39.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:48.6%;top:53.1%" aria-hidden="true">2</span><span class="gd-pin" style="left:19.8%;top:53.1%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="owners-and-onboarding-decide-on-an-application" data-gd-task><h2 class="gd-h2">Decide on an application</h2><p class="gd-p">One page holds everything: the owner, the car, the uploads, the four checks and the notes.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Check the driver&#39;s licence, the ownership, the insurance and the lender or lessor. Mark each one Checked, fine, Problem or Not needed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Approve</b>. The owner becomes active, the car gets its terms from the standard grid, the first and last month&#39;s invoices are issued, and the owner gets an email to sign and pay in the owner portal.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Missing something? Press <b class="gd-ui">Ask for something</b>, tick what you need (for example the ownership permit or the insurance slip), add a message if you like, and press <b class="gd-ui">Send to the owner</b>. The owner gets an email and a task in their portal; the application shows Waiting on owner until they answer.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Not a fit? Press <b class="gd-ui">Decline</b>, write the Reason the owner reads, and press <b class="gd-ui">Decline the application</b>. The owner is emailed for each car.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/applications/166e487a-11a1-4433-b1ca-8c2bc14bf5ca</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/812"><img src="/guides/img/admin-34-application-desktop-98b64f92.jpg" alt="" loading="lazy" decoding="async" width="1440" height="812"><span class="gd-pin" style="left:72.9%;top:67.1%" aria-hidden="true">1</span><span class="gd-pin" style="left:73.9%;top:42.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:84.7%;top:42.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:72.9%;top:49.6%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Notes on the page are for staff only: <b class="gd-ui">Add note</b> keeps a line on the record. When the owner answers a request, their answer is in the notes and the application is New again.</div></aside></section><section class="gd-task" id="owners-and-onboarding-owners" data-gd-task><h2 class="gd-h2">Owners</h2><p class="gd-p"><b class="gd-ui">Owners and partners</b> &gt; <b class="gd-ui">Owners</b>. Every owner, with their cars and where onboarding stands.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each owner shows their application, how many cars, and where onboarding stands.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">View as (owner portal)</b> shows their portal. <b class="gd-ui">Send password link</b> helps them sign in.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Invite an owner on file: fill in Name and Email under Invite an owner, then press <b class="gd-ui">Send invitation</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/owners</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/560"><img src="/guides/img/admin-12-owners-desktop-3a54d505.jpg" alt="" loading="lazy" decoding="async" width="1440" height="560"><span class="gd-pin" style="left:41%;top:42.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:37.4%;top:49.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:82.5%" aria-hidden="true">3</span></div></div></figure></div><p class="gd-p">The owner signs everything at once in their portal (Check and sign: the agreements, schedules, Forms A and B and the official forms that are ready). The confirmations to tick, then one signature: CarmaCars countersigns at the same moment, under the signing officer&#39;s standing authorization. A car with a second owner on the ownership waits for that owner too: they get their own link by email and sign the same documents.</p></section><section class="gd-task" id="owners-and-onboarding-an-owner-s-page" data-gd-task><h2 class="gd-h2">An owner&#39;s page</h2><p class="gd-p">Open an owner from Owners. The details are in the right-hand column.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Upfront invoices: issue the first and last month&#39;s insurance fee for each car whose terms are set.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Owner: address, sign-in, agreements, and what is still missing for the registry forms.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Statements and payouts for this owner.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Forms C and D, with a link to the review queue.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Further down: <b class="gd-ui">View as (owner portal)</b>, <b class="gd-ui">Send password link</b> and <b class="gd-ui">Send a sign-in link to the owner portal</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/owners/9e367055-7780-4451-822a-d79d5b59a309</span></div><div class="gd-imgwrap" style="aspect-ratio:410/1030"><img src="/guides/img/admin-13-owner-desktop-819a9f8b.jpg" alt="" loading="lazy" decoding="async" width="410" height="1030"><span class="gd-pin" style="left:24.6%;top:4.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:16.1%;top:32.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:31.5%;top:73.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:21.2%;top:98.1%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="owners-and-onboarding-paid-and-signed" data-gd-task><h2 class="gd-h2">Paid and signed</h2><p class="gd-p"><b class="gd-ui">Owners and partners</b> &gt; <b class="gd-ui">Paid and signed</b>. What each owner still has to pay or sign, and how each item was done.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each owner shows how many items are open and how many are done. Owners with nothing left are hidden; press Show every owner to see them.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open <b class="gd-ui">Checklist and quick actions</b>. Each line says Signed in the portal, Signed on paper, Paid by e-Transfer, Not signed, and so on.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Paid by e-Transfer, cheque, cash or bank transfer? Press <b class="gd-ui">Record payment</b>. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance, or type less for a partial payment. Add a photo of the cheque or a screenshot if you have one.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Signed on paper? Press <b class="gd-ui">Record paper signature</b>. Choose the Document, check Signed by and Date signed, add the witnesses where the form needs them, and upload the scan of every signed page.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The same checklist sits at the top of each owner&#39;s page.</div></li></ol></div><p class="gd-p">A recorded payment marks the invoice paid (or partly paid), stops the automatic debit for that amount, sends the owner a receipt, and shows &quot;Paid by e-Transfer on &quot; in their portal. A paper signature counts as signed everywhere: the checklist, onboarding and the owner portal. The scan is kept privately with the owner&#39;s documents.</p><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Recorded the wrong thing, or a cheque bounced? Press <b class="gd-ui">Void</b> beside it and give the reason. The invoice owes that amount again and the owner is told; a voided signature makes the item open again. Only an Admin can void.</div></aside></section><section class="gd-task" id="owners-and-onboarding-forms-c-and-d" data-gd-task><h2 class="gd-h2">Forms C and D</h2><p class="gd-p"><b class="gd-ui">Owners and partners</b> &gt; <b class="gd-ui">Owner forms</b>. Form C is signed on screen in the owner portal, with the witness on the same screen. Form D (and Form C on paper, if the owner prefers) is printed, signed in front of witnesses, and sent as a photo of each page.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each row shows the owner, the form, the witnesses and when it was uploaded.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press Open to read the photo or scan. Check each marked spot is signed or initialled.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Approve</b>, or <b class="gd-ui">Send back</b> with What to fix (the owner reads this).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/owner-forms</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/470"><img src="/guides/img/admin-22-owner-forms-desktop-c20ad300.jpg" alt="" loading="lazy" decoding="async" width="1440" height="470"><span class="gd-pin" style="left:29.2%;top:52.3%" aria-hidden="true">1</span><span class="gd-pin" style="left:57.6%;top:52.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:76.7%;top:52.3%" aria-hidden="true">3</span></div></div></figure></div></section>');
select app.guide_release_section('admin', 'owner-money', 'chapter', 'owners-and-onboarding', 'Owner fee invoices are issued on the notice day and debited on the 15th. Statements are built, approved and issued each month, and payouts follow.

## Owner invoices

›*Owner invoices

1. **Run the monthly invoices** issues the invoices for the 15th by hand, for a missed month. An invoice is never issued twice.
2. **Issue all tracker invoices** bills the Tracker Install for each car waiting for its tracker.
3. Filter by Open, Paid, Failed or In arrears. Failed invoices show the reason.
4. Paid by e-Transfer, cheque, cash or bank transfer? Press **Record payment** under the invoice. Leave Amount empty for the full balance.

![](/guides/img/admin-14-owner-invoices-desktop-dc4ed1f1.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/invoices; pins: 1 83.3 22.4, 2 41.7 35.7, 3 29.0 43.4, 4 51.6 84.3")

## The automatic debit

The debit runs by itself. Your job is to watch for returned debits and owners without a mandate.

:::flow
Notice day | The 5th: invoices issued, one notice per owner
Debit day | The 15th from 6:00: one debit per invoice
Results | Cleared: paid. Returned: $50 Late Fee once
Retry | From the 18th: the second and last try
Arrears | Returned again: a task and an email to you
:::

1. The tiles show the next debit day and notice day, scheduled, processing, cleared and returned debits.
2. How it runs explains the policy in words, read from Program settings.
3. Scheduled and processing lists each debit. **Pause** holds one (a reason is needed).
4. Owners lists each mandate. Use **Pause**, **Resume** or **Send a notice now**.

![](/guides/img/admin-15-owner-debits-desktop-f65f061a.jpg "desktop; size: 1440 920; address: carmacars.ca/admin/debits; pins: 1 21.8 21.7, 2 21.5 35.5, 3 91.5 75.4, 4 84.7 94.7")

5. Results: each debit, cleared or returned, with the bank''s reason.
6. Run log: each notice and debit run, with its counts.
7. Notices sent: who was told what, for which debit day.

![](/guides/img/admin-15-owner-debits-desktop-8d4682bc.jpg "desktop; size: 1230 520; address: carmacars.ca/admin/debits; pins: 5 11.0 14.4, 6 10.2 52.3, 7 15.4 89.8")

> Watch out: A debit is never more than its notice said. An owner with no mandate gets an email on the notice day and you get a task; nothing is debited for them. Change the days, retries and Late Fee under Debit settings (Program settings).

## Owner statements

›*Owner statements

1. Press **Build all for a month** (or **Build one**).
2. Open each draft. Check it, **Rebuild** after a correction, **Preview PDF**, then **Approve**.
3. Press **Issue to the owner**. **Reissue** sends a corrected copy; **CSV** exports it.

![](/guides/img/admin-16-statements-desktop-43a313ea.jpg "desktop; size: 1440 400; address: carmacars.ca/admin/statements; pins: 1 79.9 27.3")

![An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts.](/guides/img/admin-17-statement-desktop-106ee57f.jpg "desktop; size: 1440 520; address: carmacars.ca/admin/statements/61aa19f6-088c-4fb7-9cb9-0075624cbd80; pins: 3 86.0 22.7")

## Company statements

CarmaCars'' own monthly statement, in twelve sections.

1. Choose the month. The tiles show revenue, fees, refunds, expenses and the company net.
2. Switch between Total, Per owner and Per vehicle.
3. Download **PDF**, **PDF by owner** or **PDF by vehicle**, or press **Email me the PDFs**.
4. **Finalize** freezes the month. **Rebuild** works until then.

![](/guides/img/admin-18-company-statements-desktop-8e2738ed.jpg "desktop; size: 1440 760; address: carmacars.ca/admin/reports; pins: 1 20.8 28.0, 2 19.4 59.3, 3 77.1 15.5, 4 46.9 15.5")
', 'Owner money', 'Owner invoices, the automatic debit, statements, payouts and the company statement.',
  'Owner fee invoices are issued on the notice day and debited on the 15th. Statements are built, approved and issued each month, and payouts follow.

## Owner invoices

**Money** > **Owner invoices**

1. **Run the monthly invoices** issues the invoices for the 15th by hand, for a missed month. An invoice is never issued twice.
2. **Issue all tracker invoices** bills the Tracker Install for each car waiting for its tracker.
3. Filter by Open, Paid, Failed or In arrears. Failed invoices show the reason.
4. Paid by e-Transfer, cheque, cash or bank transfer? Press **Record payment** under the invoice. Leave Amount empty for the full balance.

![](/guides/img/admin-14-owner-invoices-desktop-dc4ed1f1.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/invoices; pins: 1 83.3 22.4, 2 41.7 35.7, 3 29.0 43.4, 4 51.6 84.3")

## The automatic debit

The debit runs by itself. Your job is to watch for returned debits and owners without a mandate.

:::flow
Notice day | Invoices issued, one notice per owner, 10 days before
Debit day | The 15th from 6:00: one debit per invoice
Cleared | The invoice is paid
Returned, insufficient funds | The $50.00 Late Fee is added once; the same amount is tried again within 30 days
Returned for another reason | No retry and no Late Fee: the debit pauses and you get a task
:::

1. The tiles show the next debit day and notice day, scheduled, processing, cleared and returned debits.
2. How it runs explains the policy in words, read from Program settings.
3. Scheduled and processing lists each debit. **Pause** holds one (a reason is needed).
4. Owners lists each mandate. Use **Pause**, **Resume** or **Send a notice now**.

![](/guides/img/admin-15-owner-debits-desktop-f65f061a.jpg "desktop; size: 1440 920; address: carmacars.ca/admin/debits; pins: 1 21.8 21.7, 2 21.5 35.5, 3 91.5 75.4, 4 84.7 94.7")

5. Results: each debit, cleared or returned, with the bank''s reason.
6. Run log: each notice and debit run, with its counts.
7. Notices sent: who was told what, for which debit day.

![](/guides/img/admin-15-owner-debits-desktop-8d4682bc.jpg "desktop; size: 1230 520; address: carmacars.ca/admin/debits; pins: 5 11.0 14.4, 6 10.2 52.3, 7 15.4 89.8")

Insufficient funds: the $50.00 Late Fee is added to that invoice once and collected with the owner''s next debit, and the original amount is tried again within 30 days, as section 4.4 of the Enrollment Agreement sets out. The retry is never more than the original amount. Returned again: the invoice is in arrears and you get a task.

> Watch out: Returned for any other reason (account closed, payment stopped, no authorization): there is no retry and no Late Fee. The owner''s debit pauses, the owner gets an email asking them to fix the account or pay another way, and you get a task. A debit is never more than its notice said. An owner with no mandate gets an email on the notice day and you get a task; nothing is debited for them.

## Owner statements

**Money** > **Owner statements**

1. Press **Build all for a month** (or **Build one**).
2. Open each draft. Check it, **Rebuild** after a correction, **Preview PDF**, then **Approve**.
3. Press **Issue to the owner**. **Reissue** sends a corrected copy; **CSV** exports it.

![](/guides/img/admin-16-statements-desktop-43a313ea.jpg "desktop; size: 1440 400; address: carmacars.ca/admin/statements; pins: 1 79.9 27.3")

![An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts.](/guides/img/admin-17-statement-desktop-106ee57f.jpg "desktop; size: 1440 520; address: carmacars.ca/admin/statements/f27936a8-9bfb-4280-81ae-c67ec47febe1; pins: 3 86.0 22.7")

## Company statements

CarmaCars'' own monthly statement, in twelve sections.

1. Choose the month. The tiles show revenue, fees, refunds, expenses and the company net.
2. Switch between Total, Per owner and Per vehicle.
3. Download **PDF**, **PDF by owner** or **PDF by vehicle**, or press **Email me the PDFs**.
4. **Finalize** freezes the month. **Rebuild** works until then.

![](/guides/img/admin-18-company-statements-desktop-8e2738ed.jpg "desktop; size: 1440 760; address: carmacars.ca/admin/reports; pins: 1 20.8 28.0, 2 19.4 59.3, 3 77.1 15.5, 4 46.9 15.5")
',
  '<p class="gd-p">Owner fee invoices are issued on the notice day and debited on the 15th. Statements are built, approved and issued each month, and payouts follow.</p><section class="gd-task" id="owner-money-owner-invoices" data-gd-task><h2 class="gd-h2">Owner invoices</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Owner invoices</b></p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Run the monthly invoices</b> issues the invoices for the 15th by hand, for a missed month. An invoice is never issued twice.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Issue all tracker invoices</b> bills the Tracker Install for each car waiting for its tracker.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Filter by Open, Paid, Failed or In arrears. Failed invoices show the reason.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Paid by e-Transfer, cheque, cash or bank transfer? Press <b class="gd-ui">Record payment</b> under the invoice. Leave Amount empty for the full balance.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/invoices</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1060"><img src="/guides/img/admin-14-owner-invoices-desktop-dc4ed1f1.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1060"><span class="gd-pin" style="left:83.3%;top:22.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:41.7%;top:35.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:29%;top:43.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:51.6%;top:84.3%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="owner-money-the-automatic-debit" data-gd-task><h2 class="gd-h2">The automatic debit</h2><p class="gd-p">The debit runs by itself. Your job is to watch for returned debits and owners without a mandate.</p><ol class="gd-flow"><li><b>1</b><span>Notice day</span><em>Invoices issued, one notice per owner, 10 days before</em></li><li><b>2</b><span>Debit day</span><em>The 15th from 6:00: one debit per invoice</em></li><li><b>3</b><span>Cleared</span><em>The invoice is paid</em></li><li><b>4</b><span>Returned, insufficient funds</span><em>The $50.00 Late Fee is added once; the same amount is tried again within 30 days</em></li><li><b>5</b><span>Returned for another reason</span><em>No retry and no Late Fee: the debit pauses and you get a task</em></li></ol><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The tiles show the next debit day and notice day, scheduled, processing, cleared and returned debits.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">How it runs explains the policy in words, read from Program settings.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Scheduled and processing lists each debit. <b class="gd-ui">Pause</b> holds one (a reason is needed).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Owners lists each mandate. Use <b class="gd-ui">Pause</b>, <b class="gd-ui">Resume</b> or <b class="gd-ui">Send a notice now</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/debits</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/920"><img src="/guides/img/admin-15-owner-debits-desktop-f65f061a.jpg" alt="" loading="lazy" decoding="async" width="1440" height="920"><span class="gd-pin" style="left:21.8%;top:21.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:21.5%;top:35.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:91.5%;top:75.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:84.7%;top:94.7%" aria-hidden="true">4</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="5"><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Results: each debit, cleared or returned, with the bank&#39;s reason.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Run log: each notice and debit run, with its counts.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Notices sent: who was told what, for which debit day.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/debits</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/520"><img src="/guides/img/admin-15-owner-debits-desktop-8d4682bc.jpg" alt="" loading="lazy" decoding="async" width="1230" height="520"><span class="gd-pin" style="left:11%;top:14.4%" aria-hidden="true">5</span><span class="gd-pin" style="left:10.2%;top:52.3%" aria-hidden="true">6</span><span class="gd-pin" style="left:15.4%;top:89.8%" aria-hidden="true">7</span></div></div></figure></div><p class="gd-p">Insufficient funds: the $50.00 Late Fee is added to that invoice once and collected with the owner&#39;s next debit, and the original amount is tried again within 30 days, as section 4.4 of the Enrollment Agreement sets out. The retry is never more than the original amount. Returned again: the invoice is in arrears and you get a task.</p><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Returned for any other reason (account closed, payment stopped, no authorization): there is no retry and no Late Fee. The owner&#39;s debit pauses, the owner gets an email asking them to fix the account or pay another way, and you get a task. A debit is never more than its notice said. An owner with no mandate gets an email on the notice day and you get a task; nothing is debited for them.</div></aside></section><section class="gd-task" id="owner-money-owner-statements" data-gd-task><h2 class="gd-h2">Owner statements</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Owner statements</b></p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Build all for a month</b> (or <b class="gd-ui">Build one</b>).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open each draft. Check it, <b class="gd-ui">Rebuild</b> after a correction, <b class="gd-ui">Preview PDF</b>, then <b class="gd-ui">Approve</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Issue to the owner</b>. <b class="gd-ui">Reissue</b> sends a corrected copy; <b class="gd-ui">CSV</b> exports it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/statements</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/400"><img src="/guides/img/admin-16-statements-desktop-43a313ea.jpg" alt="" loading="lazy" decoding="async" width="1440" height="400"><span class="gd-pin" style="left:79.9%;top:27.3%" aria-hidden="true">1</span></div></div></figure></div><div class="gd-figblock"><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/statements/f27936a8-9bfb-4280-81ae-c67ec47febe1</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/520"><img src="/guides/img/admin-17-statement-desktop-106ee57f.jpg" alt="An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts." loading="lazy" decoding="async" width="1440" height="520"><span class="gd-pin" style="left:86%;top:22.7%" aria-hidden="true">3</span></div></div><figcaption>An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts.</figcaption></figure></div></section><section class="gd-task" id="owner-money-company-statements" data-gd-task><h2 class="gd-h2">Company statements</h2><p class="gd-p">CarmaCars&#39; own monthly statement, in twelve sections.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose the month. The tiles show revenue, fees, refunds, expenses and the company net.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Switch between Total, Per owner and Per vehicle.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Download <b class="gd-ui">PDF</b>, <b class="gd-ui">PDF by owner</b> or <b class="gd-ui">PDF by vehicle</b>, or press <b class="gd-ui">Email me the PDFs</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Finalize</b> freezes the month. <b class="gd-ui">Rebuild</b> works until then.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/reports</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/760"><img src="/guides/img/admin-18-company-statements-desktop-8e2738ed.jpg" alt="" loading="lazy" decoding="async" width="1440" height="760"><span class="gd-pin" style="left:20.8%;top:28%" aria-hidden="true">1</span><span class="gd-pin" style="left:19.4%;top:59.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.1%;top:15.5%" aria-hidden="true">3</span><span class="gd-pin" style="left:46.9%;top:15.5%" aria-hidden="true">4</span></div></div></figure></div></section>');
select app.guide_release_section('admin', 'tolls-and-tickets', 'chapter', 'owner-money', 'Toll notices and tickets arrive by mail and email. Read them into the system, check each line against the notice, and the matching, charges and emails follow.

## The work queue

›*Tolls and tickets

1. Filter the queue: Unmatched, Needs review, Matched not charged, Owner not billed, Staff, Charged not notified, Disputed.
2. Each toll shows its notice, kind, issuer, plate, when, amount and who it was matched to.
3. Add one by one with **Log one**, then **Save and match**. **Import a CSV** takes a statement file.

![](/guides/img/admin-19-tolls-desktop-baa198d0.jpg "desktop; size: 1440 500; address: carmacars.ca/admin/tolls; pins: 1 31.6 32.6, 2 59.7 52.0, 3 85.8 21.8")

## Inside a toll

1. Open a toll from the queue. Decide who pays: **Charge the renter**, **Bill to the owner** or **CarmaCars pays**.
2. Wrong notice? Press **Dispute**. Finance can also press **Match again**.
3. Reading profiles (top right on Read a notice) teach the reader an issuer''s layout. Paste a notice''s text under "Try it" to test one.

## Read a notice

1. Press **Read a notice**. Choose the file: a PDF, a photo (JPEG or PNG) or a CSV, under 15 MB.
2. Leave Reading profile on finding it from the text, or choose the issuer.
3. Press **Read it**. The file is stored first, then read in your browser.
4. Notices read lists every read with its status and counts.

![](/guides/img/admin-20-tolls-read-desktop-d733b5f1.jpg "desktop; size: 1440 760; address: carmacars.ca/admin/tolls/read; pins: 1 25.8 41.2, 2 36.1 52.2, 3 21.0 59.3, 4 25.8 79.7")

## Check the lines and import

1. The notice is on the left (**Zoom**, **Open the file**). The lines are on the right.
2. Check each line beside the notice: kind, issuer, notice number, plate, date and time, amount, fees, due date.
3. Fix what was read wrong, then press **Checked against the notice**. **Leave out** skips a line; **Put it back** returns it.
4. Press **Save as checked**, then **Confirm and import**.

![](/guides/img/admin-21-tolls-review-desktop-c59d0a1c.jpg "desktop; size: 1440 1150; address: carmacars.ca/admin/tolls/read/2fd70fc1-8063-452d-a62d-01c1c16424bd; pins: 1 42.6 16.8, 2 56.7 43.8, 3 90.3 60.9, 4 76.0 38.0")

> Tip: Renters matched with high confidence are charged at import, with the notice and the administration fee, when "Charge renters matched with high confidence now" is ticked. Other lines go to the work queue or stay as exceptions with the reason.
', 'Tolls and tickets', 'The work queue, reading a notice, checking its lines and charging the right person.',
  'Toll notices and tickets arrive by mail and email. Read them into the system, check each line against the notice, and the matching, charges and emails follow.

## The work queue

**Money** > **Tolls and tickets**

1. Filter the queue: Unmatched, Needs review, Matched not charged, Owner not billed, Staff, Charged not notified, Disputed.
2. Each toll shows its notice, kind, issuer, plate, when, amount and who it was matched to.
3. Add one by one with **Log one**, then **Save and match**. **Import a CSV** takes a statement file.

![](/guides/img/admin-19-tolls-desktop-baa198d0.jpg "desktop; size: 1440 500; address: carmacars.ca/admin/tolls; pins: 1 31.6 32.6, 2 59.7 52.0, 3 85.8 21.8")

## Inside a toll

1. Open a toll from the queue. Decide who pays: **Charge the renter**, **Bill to the owner** or **CarmaCars pays**.
2. Wrong notice? Press **Dispute**. Finance can also press **Match again**.
3. Reading profiles (top right on Read a notice) teach the reader an issuer''s layout. Paste a notice''s text under "Try it" to test one.

## Read a notice

1. Press **Read a notice**. Choose the file: a PDF, a photo (JPEG or PNG) or a CSV, under 15 MB.
2. Leave Reading profile on finding it from the text, or choose the issuer.
3. Press **Read it**. The file is stored first, then read in your browser.
4. Notices read lists every read with its status and counts.

![](/guides/img/admin-20-tolls-read-desktop-d733b5f1.jpg "desktop; size: 1440 760; address: carmacars.ca/admin/tolls/read; pins: 1 25.8 41.2, 2 36.1 52.2, 3 21.0 59.3, 4 25.8 79.7")

## Check the lines and import

1. The notice is on the left (**Zoom**, **Open the file**). The lines are on the right.
2. Check each line beside the notice: kind, issuer, notice number, plate, date and time, amount, fees, due date.
3. Fix what was read wrong, then press **Checked against the notice**. **Leave out** skips a line; **Put it back** returns it.
4. Press **Save as checked**, then **Confirm and import**.

![](/guides/img/admin-21-tolls-review-desktop-c59d0a1c.jpg "desktop; size: 1440 1150; address: carmacars.ca/admin/tolls/read/ff6976ec-8955-4b2f-9c0b-aef74bb9124f; pins: 1 42.6 16.8, 2 56.7 43.8, 3 90.3 60.9, 4 76.0 38.0")

> Tip: Renters matched with high confidence are charged at import, with the notice and the administration fee, when "Charge renters matched with high confidence now" is ticked. Other lines go to the work queue or stay as exceptions with the reason.
',
  '<p class="gd-p">Toll notices and tickets arrive by mail and email. Read them into the system, check each line against the notice, and the matching, charges and emails follow.</p><section class="gd-task" id="tolls-and-tickets-the-work-queue" data-gd-task><h2 class="gd-h2">The work queue</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Tolls and tickets</b></p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Filter the queue: Unmatched, Needs review, Matched not charged, Owner not billed, Staff, Charged not notified, Disputed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each toll shows its notice, kind, issuer, plate, when, amount and who it was matched to.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Add one by one with <b class="gd-ui">Log one</b>, then <b class="gd-ui">Save and match</b>. <b class="gd-ui">Import a CSV</b> takes a statement file.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/tolls</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/500"><img src="/guides/img/admin-19-tolls-desktop-baa198d0.jpg" alt="" loading="lazy" decoding="async" width="1440" height="500"><span class="gd-pin" style="left:31.6%;top:32.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:59.7%;top:52%" aria-hidden="true">2</span><span class="gd-pin" style="left:85.8%;top:21.8%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="tolls-and-tickets-inside-a-toll" data-gd-task><h2 class="gd-h2">Inside a toll</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open a toll from the queue. Decide who pays: <b class="gd-ui">Charge the renter</b>, <b class="gd-ui">Bill to the owner</b> or <b class="gd-ui">CarmaCars pays</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Wrong notice? Press <b class="gd-ui">Dispute</b>. Finance can also press <b class="gd-ui">Match again</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Reading profiles (top right on Read a notice) teach the reader an issuer&#39;s layout. Paste a notice&#39;s text under &quot;Try it&quot; to test one.</div></li></ol></div></section><section class="gd-task" id="tolls-and-tickets-read-a-notice" data-gd-task><h2 class="gd-h2">Read a notice</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Read a notice</b>. Choose the file: a PDF, a photo (JPEG or PNG) or a CSV, under 15 MB.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Leave Reading profile on finding it from the text, or choose the issuer.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Read it</b>. The file is stored first, then read in your browser.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Notices read lists every read with its status and counts.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/tolls/read</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/760"><img src="/guides/img/admin-20-tolls-read-desktop-d733b5f1.jpg" alt="" loading="lazy" decoding="async" width="1440" height="760"><span class="gd-pin" style="left:25.8%;top:41.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:36.1%;top:52.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:21%;top:59.3%" aria-hidden="true">3</span><span class="gd-pin" style="left:25.8%;top:79.7%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="tolls-and-tickets-check-the-lines-and-import" data-gd-task><h2 class="gd-h2">Check the lines and import</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The notice is on the left (<b class="gd-ui">Zoom</b>, <b class="gd-ui">Open the file</b>). The lines are on the right.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check each line beside the notice: kind, issuer, notice number, plate, date and time, amount, fees, due date.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Fix what was read wrong, then press <b class="gd-ui">Checked against the notice</b>. <b class="gd-ui">Leave out</b> skips a line; <b class="gd-ui">Put it back</b> returns it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Save as checked</b>, then <b class="gd-ui">Confirm and import</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/tolls/read/ff6976ec-8955-4b2f-9c0b-aef74bb9124f</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1150"><img src="/guides/img/admin-21-tolls-review-desktop-c59d0a1c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1150"><span class="gd-pin" style="left:42.6%;top:16.8%" aria-hidden="true">1</span><span class="gd-pin" style="left:56.7%;top:43.8%" aria-hidden="true">2</span><span class="gd-pin" style="left:90.3%;top:60.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:76%;top:38%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Renters matched with high confidence are charged at import, with the notice and the administration fee, when &quot;Charge renters matched with high confidence now&quot; is ticked. Other lines go to the work queue or stay as exceptions with the reason.</div></aside></section>');
select app.guide_release_section('admin', 'settings', 'chapter', 'tolls-and-tickets', 'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Coverage prices, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Official ServiceOntario forms

The five official forms are loaded with a draft mapping to the owner, car, company and lender details. Until you check a form, owners get a data sheet with the values.

1. Open ›*Forms. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "The owner signs here"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed, and owners sign it with their other documents.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open ›*Investors and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Staff: open ›*Staff and roles. Under Staff agreements, press **Send the agreement to sign** beside the person. Rate, hours and the other values start from the staff profile and Program settings; change any before sending.
3. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
4. Your own PDF instead? **Send a PDF to sign** still works.
5. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
6. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

›*Guides. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## Keeping the screenshots current

The guides workflow retakes every screenshot and replaces the ones whose screen changed.

1. A guide with screens that changed shows **To review**; the section shows **Needs review** with the screenshot before and now (the new one is already in the guide).
2. Read the text against the new screenshot. Press **Suggest a text update** for a suggestion from Workers AI, then **Use this text as the draft** or **Dismiss the suggestion**.
3. Press **Mark reviewed**, then **Publish version** when the text is right, and run guides-pdf for the PDFs.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.
', 'Settings', 'Site, program settings, official forms mapping, insurers and the other lists.',
  'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Coverage prices, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Official ServiceOntario forms

The five official forms are loaded with a draft mapping to the owner, car, company and lender details. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "The owner signs here"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed, and owners sign it with their other documents.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Rate, hours and the other values start from the staff profile and Program settings; change any before sending.
4. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
5. Your own PDF instead? **Send a PDF to sign** still works.
6. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
7. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. A rewrite that did not pass the checks is not published. Its section shows **Needs review** with the suggested text: press **Use this text as the draft** or **Dismiss the suggestion**, then **Mark reviewed**.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten or wait for review, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.
',
  '<p class="gd-p">Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.</p><section class="gd-task" id="settings-the-settings-page" data-gd-task><h2 class="gd-h2">The Settings page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Site setup lists what is still missing on the public site, with <b class="gd-ui">Open site settings</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Program settings: every timing and policy value.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Forms: the official ServiceOntario PDFs and what goes in each field.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Insurers: insurance companies billed for bookings.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-24-settings-desktop-89b31691.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:32.6%;top:33%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.8%;top:40.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:40.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:25.8%;top:73.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:25.8%;top:84.9%" aria-hidden="true">5</span></div></div></figure></div><p class="gd-p">The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Coverage prices, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.</p></section><section class="gd-task" id="settings-program-settings" data-gd-task><h2 class="gd-h2">Program settings</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change a value and press <b class="gd-ui">Save</b>. It is saved as a new row from today; the rows before stay as they were.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/program</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/admin-25-program-settings-desktop-d16b066c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:25.8%;top:22%" aria-hidden="true">1</span><span class="gd-pin" style="left:27.8%;top:49%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="settings-official-serviceontario-forms" data-gd-task><h2 class="gd-h2">Official ServiceOntario forms</h2><p class="gd-p">The five official forms are loaded with a draft mapping to the owner, car, company and lender details. Until you check a form, owners get a data sheet with the values.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. Each form shows &quot;Mapping to check&quot; (a draft is ready) or &quot;Official PDF in use&quot;. Its notes say what the form is for and which boxes are left blank on purpose.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download a filled preview</b> for one car and check each value against the form.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change a field if needed: What goes in it (or &quot;The owner signs here&quot;), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for owners</b>. Every owner&#39;s form of that kind is filled again, except ones already signed or filed, and owners sign it with their other documents.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A new version from ServiceOntario? Press <b class="gd-ui">Upload the official fillable PDF</b>: the fields of the same name keep their mapping.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company&#39;s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner&#39;s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person.</div></aside></section><section class="gd-task" id="settings-agreements-to-sign-investors-and-staff" data-gd-task><h2 class="gd-h2">Agreements to sign: investors and staff</h2><p class="gd-p">Investment agreements and staff agreements are made from the person&#39;s record and signed in their own portal, or on paper.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Investor: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Investors</b> and the investor. Under Investment agreement, press <b class="gd-ui">Send the agreement to sign</b>. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press <b class="gd-ui">Send to sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Once the investor signs, the agreement shows <b class="gd-ui">Awaiting countersignature</b> on the investor&#39;s page and on To do. It is not countersigned automatically: check it and press <b class="gd-ui">Countersign</b>. CarmaCars is bound once it has countersigned and the funds clear.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Staff: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Staff</b>. Under Staff agreements, press <b class="gd-ui">Send the agreement to sign</b> beside the person. Rate, hours and the other values start from the staff profile and Program settings; change any before sending.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Your own PDF instead? <b class="gd-ui">Send a PDF to sign</b> still works.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Signed on paper instead? Press <b class="gd-ui">Record paper signature</b> in the same place and upload the scan.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Sent by mistake? Press <b class="gd-ui">Withdraw</b> and give the reason.</div></li></ol></div></section><section class="gd-task" id="settings-the-user-guides" data-gd-task><h2 class="gd-h2">The user guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Guides</b>. The guide of each portal, as people read it under Guide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each guide shows its version, when it was published and whether there are unpublished changes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a guide and press a section. Change its text and press <b class="gd-ui">Show the preview</b> to see it as people will. Press <b class="gd-ui">Save the draft</b>; each save is kept in the section&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Move a section with the arrows, hide it, or press <b class="gd-ui">Add a chapter</b>. Upload a screenshot under Screenshots and paste the line it gives you.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Publish version</b> (the next number). The portals show the new version at once.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.</div></li></ol></div></section><section class="gd-task" id="settings-the-guides-keep-up-by-themselves" data-gd-task><h2 class="gd-h2">The guides keep up by themselves</h2><p class="gd-p">After every update of the site that changes the portals, the guides are checked without anyone asking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal&#39;s own labels and menu, checked, and published. The PDFs of those guides are printed again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Such a section says <b class="gd-ui">Changed automatically on</b> and the date, in the list of guides and in the guide&#39;s editor. Not right? Open the section and press <b class="gd-ui">Revert</b>: the text it replaced comes back, published at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A rewrite that did not pass the checks is not published. Its section shows <b class="gd-ui">Needs review</b> with the suggested text: press <b class="gd-ui">Use this text as the draft</b> or <b class="gd-ui">Dismiss the suggestion</b>, then <b class="gd-ui">Mark reviewed</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The card &quot;The guides keep up by themselves&quot; at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten or wait for review, and how many PDFs were printed.</div></aside></section><section class="gd-task" id="settings-insurers-and-the-other-lists" data-gd-task><h2 class="gd-h2">Insurers and the other lists</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press <b class="gd-ui">Add</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.</div></li></ol></div></section>');
select app.guide_release_section('admin', 'email-backups-and-site-health', 'chapter', 'settings', 'Keep an eye on email use against the daily limit, the nightly backup and the occasional error page.

## Email

›*Email

1. The banner shows today''s emails against the daily limit. From 80, Admins get a notice; near the limit, digests and marketing wait first and booking and sign-in emails are held last.
2. Filter the Outbox: All, Queued, Held, Sent, Failed, Suppressed or Skipped.
3. Open an email to **Resend** or **Cancel** it.
4. Suppressions: **Suppress an address** stops all mail to it; **Lift** undoes it.

![](/guides/img/admin-23-email-desktop-dad31712.jpg "desktop; size: 1440 760; address: carmacars.ca/admin/messages; pins: 1 56.5 31.7, 2 35.5 41.8, 3 81.9 52.6, 4 26.6 22.9")

## Backups

- The database is backed up every night, encrypted, kept for 30 days and test-restored on the spot.
- Every Monday the newest backup is checked again: it must be under 30 hours old and restore cleanly.
- Nothing is emailed. A failed backup shows as a failed scheduled job under Alerts on Today. Tell your developer the same day.
- Keep a copy of the backup key in the company password manager. Without it no backup can be read.

## When a page shows "Error 1102"

Our web host''s free plan sometimes stops a page that takes too long. Reload the page; you are still signed in. Moving to the Workers Paid plan removes it.
', 'Email, backups and site health', 'The email outbox and daily limit, suppressions, backups and Error 1102.',
  'Keep an eye on email use against the daily limit, the nightly backup and the occasional error page.

## Email

**Settings** > **Email log**

1. The banner shows today''s emails against the daily limit. From 80, Admins get a notice; near the limit, digests and marketing wait first and booking and sign-in emails are held last.
2. Filter the Outbox: All, Queued, Held, Sent, Failed, Suppressed or Skipped.
3. Open an email to **Resend** or **Cancel** it.
4. Suppressions: **Suppress an address** stops all mail to it; **Lift** undoes it.

![](/guides/img/admin-23-email-desktop-dad31712.jpg "desktop; size: 1440 760; address: carmacars.ca/admin/messages; pins: 1 56.5 31.7, 2 35.5 41.8, 3 81.9 52.6, 4 26.6 22.9")

## Backups

- The database is backed up every night, encrypted, kept for 30 days and test-restored on the spot.
- Every Monday the newest backup is checked again: it must be under 30 hours old and restore cleanly.
- Nothing is emailed. A failed backup shows as a failed scheduled job under Alerts on the Overview. Tell your developer the same day.
- Keep a copy of the backup key in the company password manager. Without it no backup can be read.

## When a page shows "Error 1102"

Our web host''s free plan sometimes stops a page that takes too long. Reload the page; you are still signed in. Moving to the Workers Paid plan removes it.
',
  '<p class="gd-p">Keep an eye on email use against the daily limit, the nightly backup and the occasional error page.</p><section class="gd-task" id="email-backups-and-site-health-email" data-gd-task><h2 class="gd-h2">Email</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Email log</b></p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The banner shows today&#39;s emails against the daily limit. From 80, Admins get a notice; near the limit, digests and marketing wait first and booking and sign-in emails are held last.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Filter the Outbox: All, Queued, Held, Sent, Failed, Suppressed or Skipped.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open an email to <b class="gd-ui">Resend</b> or <b class="gd-ui">Cancel</b> it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Suppressions: <b class="gd-ui">Suppress an address</b> stops all mail to it; <b class="gd-ui">Lift</b> undoes it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/messages</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/760"><img src="/guides/img/admin-23-email-desktop-dad31712.jpg" alt="" loading="lazy" decoding="async" width="1440" height="760"><span class="gd-pin" style="left:56.5%;top:31.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:35.5%;top:41.8%" aria-hidden="true">2</span><span class="gd-pin" style="left:81.9%;top:52.6%" aria-hidden="true">3</span><span class="gd-pin" style="left:26.6%;top:22.9%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="email-backups-and-site-health-backups" data-gd-task><h2 class="gd-h2">Backups</h2><ul class="gd-ul"><li>The database is backed up every night, encrypted, kept for 30 days and test-restored on the spot.</li><li>Every Monday the newest backup is checked again: it must be under 30 hours old and restore cleanly.</li><li>Nothing is emailed. A failed backup shows as a failed scheduled job under Alerts on the Overview. Tell your developer the same day.</li><li>Keep a copy of the backup key in the company password manager. Without it no backup can be read.</li></ul></section><section class="gd-task" id="email-backups-and-site-health-when-a-page-shows-error-1102" data-gd-task><h2 class="gd-h2">When a page shows &quot;Error 1102&quot;</h2><p class="gd-p">Our web host&#39;s free plan sometimes stops a page that takes too long. Reload the page; you are still signed in. Moving to the Workers Paid plan removes it.</p></section>');
select app.guide_release_section('admin', 'quick-reference', 'reference', 'email-backups-and-site-health', '### Where things are

| Item | What it is for |
| --- | --- |
| **Today** | Alerts and what needs you now |
| **Requests** | Answer requests with offers |
| **Bookings** | Overview, Money, Changes, History |
| **Calendar** | Every car; drag, block, unblock |
| **Vehicles, Listings** | Fleet and listing pipeline |
| **Owner invoices, debits** | Fees and the 15th debit |
| **Owner statements** | Build, approve, issue |
| **Tolls and tickets** | Read a notice, work queue |
| **Portals and sign-in** | Invite, password links, View as |
| **Settings** | Site, program, forms, insurers |

### Top tasks

1. **Send an offer** ›*booking›*Send the offer
2. **Change a booking** ›*Changes›*Send to the renter
3. **Publish a listing** **Cover the plate**, then **Approve and publish**
4. **Let someone in** ›*Invite
5. **Help someone sign in** **Send password link**
6. **See what they see** **Open as this person**
7. **Read a toll notice** ›*Read a notice
8. **Monthly statements** **Build all for a month**, Approve, Issue

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **You can''t change anything** | You are viewing as someone. Press Exit on the red banner. |
| **Asked for a 6-digit code** | Open your authenticator app. Lost phone: remove the factor in the Supabase dashboard. |
', 'Quick reference', 'One page with the essentials.',
  '### Where things are

| Item | What it is for |
| --- | --- |
| **To do** | What needs you now, most urgent first |
| **Search** | Any booking, plate, VIN, name or email |
| **Bookings** | Requests, bookings, the calendar, adding a rental |
| **Cars** | Vehicles, listings, sample photos |
| **Owners and partners** | Applications, owners, partners, owner forms |
| **Money** | Owner invoices and debits, payments, statements, tolls |
| **People** | Renters, staff, investors, View as |
| **Settings** | Site, program, forms, guides, emails, audit log |

### Top tasks

1. *Answer an application:* **Owners and partners** > **Applications**, then **Approve**, **Ask for something** or **Decline**
2. *Send an offer:* **Bookings** > **Requests**, the booking, then **Send the offer**
3. *Change a booking:* The booking''s Changes tab, then **Send to the renter**
4. *Publish a listing:* **Cover the plate**, then **Approve and publish**
5. *Let someone in:* **People** > **Portals and view as**, then **Invite**
6. *Help someone sign in:* **Send password link**
7. *Read a toll notice:* **Money** > **Tolls and tickets**, then **Read a notice**
8. *Monthly statements:* **Build all for a month**, Approve, Issue

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **You can''t change anything** | You are viewing as someone. Press Exit on the red banner. |
| **Asked for a 6-digit code** | Open your authenticator app. Lost phone: remove the factor in the Supabase dashboard. |
',
  '<h3 class="gd-h3">Where things are</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Item</th><th scope="col">What it is for</th></tr></thead><tbody><tr><td><b class="gd-ui">To do</b></td><td>What needs you now, most urgent first</td></tr><tr><td><b class="gd-ui">Search</b></td><td>Any booking, plate, VIN, name or email</td></tr><tr><td><b class="gd-ui">Bookings</b></td><td>Requests, bookings, the calendar, adding a rental</td></tr><tr><td><b class="gd-ui">Cars</b></td><td>Vehicles, listings, sample photos</td></tr><tr><td><b class="gd-ui">Owners and partners</b></td><td>Applications, owners, partners, owner forms</td></tr><tr><td><b class="gd-ui">Money</b></td><td>Owner invoices and debits, payments, statements, tolls</td></tr><tr><td><b class="gd-ui">People</b></td><td>Renters, staff, investors, View as</td></tr><tr><td><b class="gd-ui">Settings</b></td><td>Site, program, forms, guides, emails, audit log</td></tr></tbody></table></div><h3 class="gd-h3">Top tasks</h3><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><em>Answer an application:</em> <b class="gd-ui">Owners and partners</b> &gt; <b class="gd-ui">Applications</b>, then <b class="gd-ui">Approve</b>, <b class="gd-ui">Ask for something</b> or <b class="gd-ui">Decline</b></div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><em>Send an offer:</em> <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Requests</b>, the booking, then <b class="gd-ui">Send the offer</b></div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><em>Change a booking:</em> The booking&#39;s Changes tab, then <b class="gd-ui">Send to the renter</b></div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><em>Publish a listing:</em> <b class="gd-ui">Cover the plate</b>, then <b class="gd-ui">Approve and publish</b></div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><em>Let someone in:</em> <b class="gd-ui">People</b> &gt; <b class="gd-ui">Portals and view as</b>, then <b class="gd-ui">Invite</b></div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><em>Help someone sign in:</em> <b class="gd-ui">Send password link</b></div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><em>Read a toll notice:</em> <b class="gd-ui">Money</b> &gt; <b class="gd-ui">Tolls and tickets</b>, then <b class="gd-ui">Read a notice</b></div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t"><em>Monthly statements:</em> <b class="gd-ui">Build all for a month</b>, Approve, Issue</div></li></ol></div><h3 class="gd-h3">If something goes wrong</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">What you see</th><th scope="col">What to do</th></tr></thead><tbody><tr><td><b class="gd-ui">A link says it expired</b></td><td>Links in our emails work for 24 hours, once. Press <b class="gd-ui">Send me a new link</b> on that page.</td></tr><tr><td><b class="gd-ui">&quot;Error 1102&quot; on a page</b></td><td>A short limit on our web host. Reload the page. You are still signed in.</td></tr><tr><td><b class="gd-ui">&quot;That email and password do not match an account.&quot;</b></td><td>Check the address, or use <b class="gd-ui">Set a new password</b> on the sign-in page.</td></tr><tr><td><b class="gd-ui">You can&#39;t change anything</b></td><td>You are viewing as someone. Press Exit on the red banner.</td></tr><tr><td><b class="gd-ui">Asked for a 6-digit code</b></td><td>Open your authenticator app. Lost phone: remove the factor in the Supabase dashboard.</td></tr></tbody></table></div>');
select app.guide_release_section('va', 'start-here', 'start', null, '### Who this guide is for

CarmaCars assistants (VAs) in Customer service, Finance, Fleet and Sales. Read chapter 1, then the chapter for your function. If you cover more than one, read each of them.

### What you need

- The invitation email from CarmaCars (the link works for 24 hours)
- A computer for your shift. The portal also works on a phone
- An authenticator app on your phone, if your Admin turns on two-step sign-in

## Your first sign-in

1. Open the invitation email and press its link within 24 hours. Choose a password of 8 characters or more and press **Save the new password**.
2. You land in your portal, on **Queue**, working as your main function.
3. Next time, sign in at `carmacars.ca/sign-in` with your Email and Password, then **Sign in**.
4. Link expired? Press **Send me a new link** on the page it opens, or ask an Admin for a password link.

![](/guides/img/public-09-sign-in-phone-1f766061.jpg "phone; size: 390 645; pins: 3 95.4 78.4")

> Good to know: Recommended: open your profile and press **Set up two-step sign-in**. Scan the code with your authenticator app, type the 6 digits and press **Continue**. After that every sign-in asks for a code.
', 'Start here', 'Who this is for and your first sign-in.',
  '### Who this guide is for

CarmaCars assistants (VAs) in Customer service, Finance, Fleet and Sales. Read chapter 1, then the chapter for your function. If you cover more than one, read each of them.

### What you need

- The invitation email from CarmaCars (the link works for 24 hours)
- A computer for your shift. The portal also works on a phone
- An authenticator app on your phone, if your Admin turns on two-step sign-in

## Your first sign-in

1. Open the invitation email and press its link within 24 hours. Choose a password of 8 characters or more and press **Save the new password**.
2. You land in your portal, on **To do**, working as your main function.
3. Next time, sign in at `carmacars.ca/sign-in` with your Email and Password, then **Sign in**.
4. Link expired? Press **Send me a new link** on the page it opens, or ask an Admin for a password link.

![](/guides/img/public-09-sign-in-phone-1f766061.jpg "phone; size: 390 645; pins: 3 95.4 78.4")

> Good to know: Recommended: open your profile and press **Set up two-step sign-in**. Scan the code with your authenticator app, type the 6 digits and press **Continue**. After that every sign-in asks for a code.
',
  '<h3 class="gd-h3">Who this guide is for</h3><p class="gd-p">CarmaCars assistants (VAs) in Customer service, Finance, Fleet and Sales. Read chapter 1, then the chapter for your function. If you cover more than one, read each of them.</p><h3 class="gd-h3">What you need</h3><ul class="gd-ul"><li>The invitation email from CarmaCars (the link works for 24 hours)</li><li>A computer for your shift. The portal also works on a phone</li><li>An authenticator app on your phone, if your Admin turns on two-step sign-in</li></ul><section class="gd-task" id="start-here-your-first-sign-in" data-gd-task><h2 class="gd-h2">Your first sign-in</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the invitation email and press its link within 24 hours. Choose a password of 8 characters or more and press <b class="gd-ui">Save the new password</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">You land in your portal, on <b class="gd-ui">To do</b>, working as your main function.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Next time, sign in at <span class="gd-url">carmacars.ca/sign-in</span> with your Email and Password, then <b class="gd-ui">Sign in</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Link expired? Press <b class="gd-ui">Send me a new link</b> on the page it opens, or ask an Admin for a password link.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/645"><img src="/guides/img/public-09-sign-in-phone-1f766061.jpg" alt="" loading="lazy" decoding="async" width="390" height="645"><span class="gd-pin" style="left:95.4%;top:78.4%" aria-hidden="true">3</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Recommended: open your profile and press <b class="gd-ui">Set up two-step sign-in</b>. Scan the code with your authenticator app, type the 6 digits and press <b class="gd-ui">Continue</b>. After that every sign-in asks for a code.</div></aside></section>');
select app.guide_release_section('va', 'your-workday', 'chapter', 'start-here', 'Every function works the same way: start on Queue, take the oldest task, finish it, and check Today for pickups and returns.

## The queue

Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more.

1. The top line shows your function and how many tasks are open.
2. Filter: All, Mine, Unassigned or Waiting; Any time, Overdue, Due today or Escalated; and by type.
3. Each row has a priority, the task, its record, when it is due and how long it has waited. The oldest due is first.
4. Press **Take it** to make it yours. **Sheet** opens the step-by-step procedure.

![](/guides/img/va-cs-01-queue-desktop-c36a8e2d.jpg "desktop; size: 1440 640; address: carmacars.ca/va; pins: 1 13.9 5.0, 2 36.1 17.5, 3 31.9 43.8, 4 91.7 52.3")

## Work a task

Open the task. The buttons along the top move it on.

| Button | What it does |
| --- | --- |
| **Open the working screen** | Jumps to the booking, car or owner the task is about. |
| **Done** | You finished it. It leaves the queue. |
| **Waiting** | You are waiting on someone (a renter, an owner). It stays yours. |
| **Escalate** | It needs an Admin. Add why. |
| **Hand over** | Give it to someone else on the team. |
| **Add a note** | Leave a note for whoever looks next. |

> Tip: Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.

## Today

1. Today lists pickups and returns, and what is due, for your function.
2. Press a booking number to open it. **Queue** takes you back to your tasks.

![](/guides/img/va-cs-02-today-desktop-dfd277b7.jpg "desktop; size: 1440 700; address: carmacars.ca/va/today; pins: 1 20.8 14.3")

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. The queue shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, hours, rate and start date), then press **Read the PDF** and read it.
3. Press **Sign**. Your full legal name is your signature (or press **Draw instead**). Several documents? One signature covers all of them. The signed copy stays on the same page.

## Several functions? Switch with Working as

If you cover more than one function, **Working as** at the top of the rail lists them: Customer service, Finance, Fleet and Sales. Choose one; the rail, the queue and Today change to that function.

## Your scorecard

1. Open **Scorecard** at the bottom of the rail.
2. By week shows each measure, its target and your result for each week.
3. A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.

![](/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg "desktop; size: 1440 360; address: carmacars.ca/va/scorecard; pins: 1 4.2 39.7, 2 62.5 58.3")
', 'Your workday', 'The menu, To do, task actions, Today, switching functions and your scorecard.',
  'Every function works the same way: start on To do, take the oldest task, finish it, and check Today for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.

## The menu

My work comes first: To do, Today and My scorecard. Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.

| Function | Groups and pages |
| --- | --- |
| Customer service | Bookings (Requests, New quote, Add a rental, Calendar), Renters (Messages, Find a renter), Cars (Listings, Similar cars), Owners (Owners and enquiries, Owner forms) |
| Sales | Bookings (Requests and offers, New quote, Add a rental, Calendar), Owners (Owner leads) |
| Finance | Money (Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar) |
| Fleet | Field work (Field jobs, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar), Renters (Find a renter) |

## To do

Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more.

1. The top line shows your function and how many tasks are open.
2. Filter: All, Mine, Unassigned or Waiting; Any time, Overdue, Due today or Escalated; and by type.
3. Each row has a priority, the task, its record, when it is due and how long it has waited. The oldest due is first.
4. Press **Take it** to make it yours. **Sheet** opens the step-by-step procedure.

![](/guides/img/va-cs-01-queue-desktop-c36a8e2d.jpg "desktop; size: 1440 640; address: carmacars.ca/va; pins: 1 13.9 5.0, 2 36.1 17.5, 3 31.9 43.8, 4 91.7 52.3")

## Work a task

Open the task. The buttons along the top move it on.

| Button | What it does |
| --- | --- |
| **Open the working screen** | Jumps to the booking, car or owner the task is about. |
| **Done** | You finished it. It leaves the queue. |
| **Waiting** | You are waiting on someone (a renter, an owner). It stays yours. |
| **Escalate** | It needs an Admin. Add why. |
| **Hand over** | Give it to someone else on the team. |
| **Add a note** | Leave a note for whoever looks next. |

> Tip: Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.

## Today

1. Today lists pickups and returns, and what is due, for your function.
2. Press a booking number to open it. **To do** takes you back to your tasks.

![](/guides/img/va-cs-02-today-desktop-dfd277b7.jpg "desktop; size: 1440 700; address: carmacars.ca/va/today; pins: 1 20.8 14.3")

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. The queue shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, hours, rate and start date), then press **Read the PDF** and read it.
3. Press **Sign**. Your full legal name is your signature (or press **Draw instead**). Several documents? One signature covers all of them. The signed copy stays on the same page.

## Several functions? Switch with Working as

If you cover more than one function, **Working as** above the menu lists them: Customer service, Finance, Fleet and Sales. Choose one; the menu, To do and Today change to that function.

## Your scorecard

1. Open **My work** > **My scorecard**.
2. By week shows each measure, its target and your result for each week.
3. A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.

![](/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg "desktop; size: 1440 360; address: carmacars.ca/va/scorecard; pins: 1 4.2 39.7, 2 62.5 58.3")
',
  '<p class="gd-p">Every function works the same way: start on To do, take the oldest task, finish it, and check Today for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.</p><section class="gd-task" id="your-workday-the-menu" data-gd-task><h2 class="gd-h2">The menu</h2><p class="gd-p">My work comes first: To do, Today and My scorecard. Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Function</th><th scope="col">Groups and pages</th></tr></thead><tbody><tr><td>Customer service</td><td>Bookings (Requests, New quote, Add a rental, Calendar), Renters (Messages, Find a renter), Cars (Listings, Similar cars), Owners (Owners and enquiries, Owner forms)</td></tr><tr><td>Sales</td><td>Bookings (Requests and offers, New quote, Add a rental, Calendar), Owners (Owner leads)</td></tr><tr><td>Finance</td><td>Money (Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar)</td></tr><tr><td>Fleet</td><td>Field work (Field jobs, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar), Renters (Find a renter)</td></tr></tbody></table></div></section><section class="gd-task" id="your-workday-to-do" data-gd-task><h2 class="gd-h2">To do</h2><p class="gd-p">Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The top line shows your function and how many tasks are open.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Filter: All, Mine, Unassigned or Waiting; Any time, Overdue, Due today or Escalated; and by type.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each row has a priority, the task, its record, when it is due and how long it has waited. The oldest due is first.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Take it</b> to make it yours. <b class="gd-ui">Sheet</b> opens the step-by-step procedure.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/va-cs-01-queue-desktop-c36a8e2d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:13.9%;top:5%" aria-hidden="true">1</span><span class="gd-pin" style="left:36.1%;top:17.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:31.9%;top:43.8%" aria-hidden="true">3</span><span class="gd-pin" style="left:91.7%;top:52.3%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="your-workday-work-a-task" data-gd-task><h2 class="gd-h2">Work a task</h2><p class="gd-p">Open the task. The buttons along the top move it on.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Button</th><th scope="col">What it does</th></tr></thead><tbody><tr><td><b class="gd-ui">Open the working screen</b></td><td>Jumps to the booking, car or owner the task is about.</td></tr><tr><td><b class="gd-ui">Done</b></td><td>You finished it. It leaves the queue.</td></tr><tr><td><b class="gd-ui">Waiting</b></td><td>You are waiting on someone (a renter, an owner). It stays yours.</td></tr><tr><td><b class="gd-ui">Escalate</b></td><td>It needs an Admin. Add why.</td></tr><tr><td><b class="gd-ui">Hand over</b></td><td>Give it to someone else on the team.</td></tr><tr><td><b class="gd-ui">Add a note</b></td><td>Leave a note for whoever looks next.</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.</div></aside></section><section class="gd-task" id="your-workday-today" data-gd-task><h2 class="gd-h2">Today</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Today lists pickups and returns, and what is due, for your function.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press a booking number to open it. <b class="gd-ui">To do</b> takes you back to your tasks.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/today</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/700"><img src="/guides/img/va-cs-02-today-desktop-dfd277b7.jpg" alt="" loading="lazy" decoding="async" width="1440" height="700"><span class="gd-pin" style="left:20.8%;top:14.3%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="your-workday-documents-to-sign" data-gd-task><h2 class="gd-h2">Documents to sign</h2><p class="gd-p">Your staff agreement, when CarmaCars sends it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The queue shows &quot;You have a document to sign&quot;. Press <b class="gd-ui">Read and sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the key values at the top (your role, hours, rate and start date), then press <b class="gd-ui">Read the PDF</b> and read it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Sign</b>. Your full legal name is your signature (or press <b class="gd-ui">Draw instead</b>). Several documents? One signature covers all of them. The signed copy stays on the same page.</div></li></ol></div></section><section class="gd-task" id="your-workday-several-functions-switch-with-working-as" data-gd-task><h2 class="gd-h2">Several functions? Switch with Working as</h2><p class="gd-p">If you cover more than one function, <b class="gd-ui">Working as</b> above the menu lists them: Customer service, Finance, Fleet and Sales. Choose one; the menu, To do and Today change to that function.</p></section><section class="gd-task" id="your-workday-your-scorecard" data-gd-task><h2 class="gd-h2">Your scorecard</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">My work</b> &gt; <b class="gd-ui">My scorecard</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">By week shows each measure, its target and your result for each week.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/scorecard</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/360"><img src="/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg" alt="" loading="lazy" decoding="async" width="1440" height="360"><span class="gd-pin" style="left:4.2%;top:39.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:62.5%;top:58.3%" aria-hidden="true">2</span></div></div></figure></div></section>');
select app.guide_release_section('va', 'customer-service', 'chapter', 'your-workday', 'You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter''s first person.

Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.

## Answer a request

1. Open **Requests**. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.
2. Waiting shows how long the renter has waited. Open the booking number.

![](/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg "desktop; size: 1440 640; address: carmacars.ca/va/requests; pins: 1 27.1 17.5, 2 52.8 32.8")

3. On the Review tab, check the request: the car is free, the renter, the places.
4. Press **Adjust the booking** to change the car, dates, places, price or extras, then **Save changes**.
5. Add a message and press **Send the offer**. Within your limit you can also use **Approve (within my limit)** or **Approve and send the pay link**.
6. Can''t do it? **Decline** with Reason and any alternative. Need to know more? **Ask the renter**.

![](/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg "desktop; size: 1440 1000; address: carmacars.ca/va/bookings/CC-10020?tab=review; pins: 3 69.4 24.0, 4 95.8 98.0")

> Tip: Aim to send the offer within 15 minutes of the request. That is the "Quote sent" measure on your scorecard.

## New quote for a caller

1. Open **New quote**. Choose the Car, the Pickup and Return (at least 2 hours from now).
2. Choose how the lead came in, then the caller''s Full legal name, Email, Mobile and Date of birth.
3. Set the Licence class and Damage cover, and note places, extras and what they asked.
4. Press **Create the request**. It opens like any request; send the offer from there.

![](/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg "desktop; size: 1220 1260; address: carmacars.ca/va/quotes/new; pins: 1 72.1 15.6, 2 72.1 41.7, 3 72.1 72.7, 4 63.9 85.5")

## Renter messages and Find a renter

1. **Renter messages** lists the latest messages with their booking. Open the booking to reply, then press **Send**.
2. **Find a renter**: search by name, email, phone or booking number.
3. To open a renter''s private details, press **Open with a reason**. The reason is kept in the access log.

![](/guides/img/va-cs-06-messages-desktop-3441fa91.jpg "desktop; size: 1440 260; address: carmacars.ca/va/messages; pins: 1 32.6 48.5")

## Owner forms (Forms C and D)

1. Open **Owner forms**. Each row is a scan an owner uploaded, with the witnesses and the status.
2. Press Open to read the scan. Check every page is there and signed, with each witness''s signature and name.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg "desktop; size: 1440 300; address: carmacars.ca/va/owner-forms; pins: 2 68.6 36.7, 3 76.7 36.7")

## A rental agreement signed on paper

1. Open the booking. Under Signed on paper, press **Record paper signature**.
2. Choose the Rental agreement, or the booking change the renter signed.
3. Check Signed by and Date signed, and upload the scan of every signed page.
4. Press **Record signature**. It counts as signed, and the renter is not asked to sign again.

## A change to a confirmed booking

On a booking''s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press **Preview the price**, then **Send to the renter**. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.

## A late return

A booking past its return time shows the late return panel. Work it in order:

| Button | When |
| --- | --- |
| **Log a call** | Record each call to the renter and what they said. |
| **Send T13** | The first late notice email. |
| **Send T14 (final notice)** | The final notice. |
| **Request disable** | Ask an Admin to approve disabling the car. |
| **Open an incident** | When the car is not coming back as planned. |
', 'Customer service', 'Requests and offers, new quotes, renter messages, find a renter, owner forms, late returns.',
  'You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter''s first person.

Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.

## Answer a request

1. Open **Requests**. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.
2. Waiting shows how long the renter has waited. Open the booking number.

![](/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg "desktop; size: 1440 640; address: carmacars.ca/va/requests; pins: 1 27.1 17.5, 2 52.8 32.8")

3. On the Review tab, check the request: the car is free, the renter, the places.
4. Press **Adjust the booking** to change the car, dates, places, price or extras, then **Save changes**.
5. Add a message and press **Send the offer**. Within your limit you can also use **Approve (within my limit)** or **Approve and send the pay link**.
6. Can''t do it? **Decline** with Reason and any alternative. Need to know more? **Ask the renter**.

![](/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg "desktop; size: 1440 1000; address: carmacars.ca/va/bookings/CC-10056?tab=review; pins: 3 69.4 24.0, 4 95.8 98.0")

> Tip: Aim to send the offer within 15 minutes of the request. That is the "Quote sent" measure on your scorecard.

## New quote for a caller

1. Open **New quote**. Choose the Car, the Pickup and Return (at least 2 hours from now).
2. Choose how the lead came in, then the caller''s Full legal name, Email, Mobile and Date of birth.
3. Set the Licence class and Damage cover, and note places, extras and what they asked.
4. Press **Create the request**. It opens like any request; send the offer from there.

![](/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg "desktop; size: 1220 1260; address: carmacars.ca/va/quotes/new; pins: 1 72.1 15.6, 2 72.1 41.7, 3 72.1 72.7, 4 63.9 85.5")

## Renter messages and Find a renter

1. **Renter messages** lists the latest messages with their booking. Open the booking to reply, then press **Send**.
2. **Find a renter**: search by name, email, phone or booking number.
3. To open a renter''s private details, press **Open with a reason**. The reason is kept in the access log.

![](/guides/img/va-cs-06-messages-desktop-3441fa91.jpg "desktop; size: 1440 260; address: carmacars.ca/va/messages; pins: 1 32.6 48.5")

## Owner forms (Forms C and D)

1. Open **Owner forms**. Each row is a scan an owner uploaded, with the witnesses and the status.
2. Press Open to read the scan. Check every page is there and signed, with each witness''s signature and name.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg "desktop; size: 1440 300; address: carmacars.ca/va/owner-forms; pins: 2 68.6 36.7, 3 76.7 36.7")

## A rental agreement signed on paper

1. Open the booking. Under Signed on paper, press **Record paper signature**.
2. Choose the Rental agreement, or the booking change the renter signed.
3. Check Signed by and Date signed, and upload the scan of every signed page.
4. Press **Record signature**. It counts as signed, and the renter is not asked to sign again.

## A change to a confirmed booking

On a booking''s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press **Preview the price**, then **Send to the renter**. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.

## A late return

A booking past its return time shows the late return panel. Work it in order:

| Button | When |
| --- | --- |
| **Log a call** | Record each call to the renter and what they said. |
| **Send T13** | The first late notice email. |
| **Send T14 (final notice)** | The final notice. |
| **Request disable** | Ask an Admin to approve disabling the car. |
| **Open an incident** | When the car is not coming back as planned. |
',
  '<p class="gd-p">You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter&#39;s first person.</p><p class="gd-p">Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.</p><section class="gd-task" id="customer-service-answer-a-request" data-gd-task><h2 class="gd-h2">Answer a request</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Requests</b>. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Waiting shows how long the renter has waited. Open the booking number.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:27.1%;top:17.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:52.8%;top:32.8%" aria-hidden="true">2</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the Review tab, check the request: the car is free, the renter, the places.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Adjust the booking</b> to change the car, dates, places, price or extras, then <b class="gd-ui">Save changes</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Add a message and press <b class="gd-ui">Send the offer</b>. Within your limit you can also use <b class="gd-ui">Approve (within my limit)</b> or <b class="gd-ui">Approve and send the pay link</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Can&#39;t do it? <b class="gd-ui">Decline</b> with Reason and any alternative. Need to know more? <b class="gd-ui">Ask the renter</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:69.4%;top:24%" aria-hidden="true">3</span><span class="gd-pin" style="left:95.8%;top:98%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Aim to send the offer within 15 minutes of the request. That is the &quot;Quote sent&quot; measure on your scorecard.</div></aside></section><section class="gd-task" id="customer-service-new-quote-for-a-caller" data-gd-task><h2 class="gd-h2">New quote for a caller</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">New quote</b>. Choose the Car, the Pickup and Return (at least 2 hours from now).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose how the lead came in, then the caller&#39;s Full legal name, Email, Mobile and Date of birth.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Set the Licence class and Damage cover, and note places, extras and what they asked.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Create the request</b>. It opens like any request; send the offer from there.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/quotes/new</span></div><div class="gd-imgwrap" style="aspect-ratio:1220/1260"><img src="/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg" alt="" loading="lazy" decoding="async" width="1220" height="1260"><span class="gd-pin" style="left:72.1%;top:15.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:72.1%;top:41.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:72.1%;top:72.7%" aria-hidden="true">3</span><span class="gd-pin" style="left:63.9%;top:85.5%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="customer-service-renter-messages-and-find-a-renter" data-gd-task><h2 class="gd-h2">Renter messages and Find a renter</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Renter messages</b> lists the latest messages with their booking. Open the booking to reply, then press <b class="gd-ui">Send</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Find a renter</b>: search by name, email, phone or booking number.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To open a renter&#39;s private details, press <b class="gd-ui">Open with a reason</b>. The reason is kept in the access log.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/messages</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/260"><img src="/guides/img/va-cs-06-messages-desktop-3441fa91.jpg" alt="" loading="lazy" decoding="async" width="1440" height="260"><span class="gd-pin" style="left:32.6%;top:48.5%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="customer-service-owner-forms-forms-c-and-d" data-gd-task><h2 class="gd-h2">Owner forms (Forms C and D)</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Owner forms</b>. Each row is a scan an owner uploaded, with the witnesses and the status.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press Open to read the scan. Check every page is there and signed, with each witness&#39;s signature and name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Approve</b>, or <b class="gd-ui">Send back</b> with What to fix (the owner reads this).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/owner-forms</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/300"><img src="/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg" alt="" loading="lazy" decoding="async" width="1440" height="300"><span class="gd-pin" style="left:68.6%;top:36.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:76.7%;top:36.7%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="customer-service-a-rental-agreement-signed-on-paper" data-gd-task><h2 class="gd-h2">A rental agreement signed on paper</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking. Under Signed on paper, press <b class="gd-ui">Record paper signature</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the Rental agreement, or the booking change the renter signed.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check Signed by and Date signed, and upload the scan of every signed page.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Record signature</b>. It counts as signed, and the renter is not asked to sign again.</div></li></ol></div></section><section class="gd-task" id="customer-service-a-change-to-a-confirmed-booking" data-gd-task><h2 class="gd-h2">A change to a confirmed booking</h2><p class="gd-p">On a booking&#39;s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press <b class="gd-ui">Preview the price</b>, then <b class="gd-ui">Send to the renter</b>. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.</p></section><section class="gd-task" id="customer-service-a-late-return" data-gd-task><h2 class="gd-h2">A late return</h2><p class="gd-p">A booking past its return time shows the late return panel. Work it in order:</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Button</th><th scope="col">When</th></tr></thead><tbody><tr><td><b class="gd-ui">Log a call</b></td><td>Record each call to the renter and what they said.</td></tr><tr><td><b class="gd-ui">Send T13</b></td><td>The first late notice email.</td></tr><tr><td><b class="gd-ui">Send T14 (final notice)</b></td><td>The final notice.</td></tr><tr><td><b class="gd-ui">Request disable</b></td><td>Ask an Admin to approve disabling the car.</td></tr><tr><td><b class="gd-ui">Open an incident</b></td><td>When the car is not coming back as planned.</td></tr></tbody></table></div></section>');
select app.guide_release_section('va', 'add-a-rental-by-hand', 'chapter', 'sales', 'Customer service and Sales add rentals that come in by phone, at the counter, from Turo, a partner or an insurer. The rental is confirmed and on the calendar at once.

## Add a rental

Open **Add a rental** on your rail.

1. Choose the car, the dates and the places. The check shows any clash with another booking or with the cleaning time after a trip. You cannot book over a clash: ask an Admin.
2. Find the renter by name, email or phone, or add a new one with their name, email, phone, date of birth and licence. Add any other drivers.
3. Press **Check the calendar and the price**. The price comes from the rate sheet. You may add the extras, the coverage and an allowed promo code; a price typed by hand is for Admins.
4. Choose Where it came from and how it is paid. The ways open to you are set by an Admin, such as **Paid another way**, **Send a payment link** or **Charge the saved card**.
5. Press **Add the rental**. The renter gets the confirmation email unless you tick **Do not email the renter**.

> Tip: The renter signs the rental agreement in their portal before pickup. If they sign on paper at the counter, an Admin records it. A payment link keeps the booking waiting for payment.
', 'Add a rental by hand', 'Choose the car and dates, find the renter, price it, record how it is paid.',
  'Customer service and Sales add rentals that come in by phone, at the counter, from Turo, a partner or an insurer. The rental is confirmed and on the calendar at once.

## Add a rental

Open **Bookings** > **Add a rental**.

1. Choose the car, the dates and the places. The check shows any clash with another booking or with the cleaning time after a trip. You cannot book over a clash: ask an Admin.
2. Find the renter by name, email or phone, or add a new one with their name, email, phone, date of birth and licence. Add any other drivers.
3. Press **Check the calendar and the price**. The price comes from the rate sheet. You may add the extras, the coverage and an allowed promo code; a price typed by hand is for Admins.
4. Choose Where it came from and how it is paid. The ways open to you are set by an Admin, such as **Paid another way**, **Send a payment link** or **Charge the saved card when the renter signs**.
5. Press **Add the rental**. The renter gets the confirmation email unless you tick **Do not email the renter**.

> Tip: The renter signs the rental agreement in their portal before pickup. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign. If they sign on paper at the counter, an Admin records it. A payment link keeps the booking waiting for payment.
',
  '<p class="gd-p">Customer service and Sales add rentals that come in by phone, at the counter, from Turo, a partner or an insurer. The rental is confirmed and on the calendar at once.</p><section class="gd-task" id="add-a-rental-by-hand-add-a-rental" data-gd-task><h2 class="gd-h2">Add a rental</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Add a rental</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose the car, the dates and the places. The check shows any clash with another booking or with the cleaning time after a trip. You cannot book over a clash: ask an Admin.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Find the renter by name, email or phone, or add a new one with their name, email, phone, date of birth and licence. Add any other drivers.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Check the calendar and the price</b>. The price comes from the rate sheet. You may add the extras, the coverage and an allowed promo code; a price typed by hand is for Admins.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Choose Where it came from and how it is paid. The ways open to you are set by an Admin, such as <b class="gd-ui">Paid another way</b>, <b class="gd-ui">Send a payment link</b> or <b class="gd-ui">Charge the saved card when the renter signs</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Add the rental</b>. The renter gets the confirmation email unless you tick <b class="gd-ui">Do not email the renter</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The renter signs the rental agreement in their portal before pickup. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign. If they sign on paper at the counter, an Admin records it. A payment link keeps the booking waiting for payment.</div></aside></section>');
select app.guide_release_section('va', 'quick-reference', 'reference', 'shared-tools', '### Where things are

| Item | What it is for |
| --- | --- |
| **Queue** | Your function''s tasks, oldest due first |
| **Today** | Pickups, returns, what is due |
| **Working as** | Switch function (top of the rail) |
| **Customer service** | Requests, New quote, Renter messages, Owner forms |
| **Finance** | Payments, Tolls and tickets, Reconciliation, Turo trips |
| **Fleet** | Field jobs, Daily checks, Photo reviews, Listings, Similar cars |
| **Sales** | Requests and offers, New quote, Owner leads |
| **Scorecard** | Your results by week |

### Top tasks

1. **Take a task** ›*Take it, then **Done**
2. **Send an offer** ›*booking›*Send the offer
3. **Quote a caller** ›*Create the request
4. **Review Forms C and D** ›*Approve
5. **Read a toll notice** ›*Read a notice
6. **Issue a refund** **Request the refund**, **Issue the refund**
7. **Schedule a field job** ›*Schedule
8. **Cover a plate** **Cover the plate**, **Save the covered photo**

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **A task is above your limit** | Press **Escalate** and say why. An Admin picks it up. |
| **Asked for a 6-digit code** | Open your authenticator app. Lost your phone? Tell an Admin. |
', 'Quick reference', 'One page with the essentials.',
  '### Where things are

| Item | What it is for |
| --- | --- |
| **To do** | Your function''s tasks, oldest due first |
| **Today** | Pickups, returns, what is due |
| **Working as** | Switch function (above the menu) |
| **Customer service** | Requests, New quote, Renter messages, Owner forms |
| **Finance** | Payments, Tolls and tickets, Reconciliation, Turo trips |
| **Fleet** | Field jobs, Daily checks, Photo reviews, Listings, Similar cars |
| **Sales** | Requests and offers, New quote, Owner leads |
| **My scorecard** | Your results by week |

### Top tasks

1. *Take a task:* **My work** > **To do**, **Take it**, then **Done**
2. *Send an offer:* **Bookings** > **Requests**, the booking, then **Send the offer**
3. *Quote a caller:* **Bookings** > **New quote**, then **Create the request**
4. *Review Forms C and D:* **Owner forms** > **Approve**
5. *Read a toll notice:* **Tolls and tickets** > **Read a notice**
6. *Issue a refund:* **Request the refund**, **Issue the refund**
7. *Schedule a field job:* **Field jobs** > **Schedule**
8. *Cover a plate:* **Cover the plate**, **Save the covered photo**

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **A task is above your limit** | Press **Escalate** and say why. An Admin picks it up. |
| **Asked for a 6-digit code** | Open your authenticator app. Lost your phone? Tell an Admin. |
',
  '<h3 class="gd-h3">Where things are</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Item</th><th scope="col">What it is for</th></tr></thead><tbody><tr><td><b class="gd-ui">To do</b></td><td>Your function&#39;s tasks, oldest due first</td></tr><tr><td><b class="gd-ui">Today</b></td><td>Pickups, returns, what is due</td></tr><tr><td><b class="gd-ui">Working as</b></td><td>Switch function (above the menu)</td></tr><tr><td><b class="gd-ui">Customer service</b></td><td>Requests, New quote, Renter messages, Owner forms</td></tr><tr><td><b class="gd-ui">Finance</b></td><td>Payments, Tolls and tickets, Reconciliation, Turo trips</td></tr><tr><td><b class="gd-ui">Fleet</b></td><td>Field jobs, Daily checks, Photo reviews, Listings, Similar cars</td></tr><tr><td><b class="gd-ui">Sales</b></td><td>Requests and offers, New quote, Owner leads</td></tr><tr><td><b class="gd-ui">My scorecard</b></td><td>Your results by week</td></tr></tbody></table></div><h3 class="gd-h3">Top tasks</h3><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><em>Take a task:</em> <b class="gd-ui">My work</b> &gt; <b class="gd-ui">To do</b>, <b class="gd-ui">Take it</b>, then <b class="gd-ui">Done</b></div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><em>Send an offer:</em> <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Requests</b>, the booking, then <b class="gd-ui">Send the offer</b></div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><em>Quote a caller:</em> <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">New quote</b>, then <b class="gd-ui">Create the request</b></div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><em>Review Forms C and D:</em> <b class="gd-ui">Owner forms</b> &gt; <b class="gd-ui">Approve</b></div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><em>Read a toll notice:</em> <b class="gd-ui">Tolls and tickets</b> &gt; <b class="gd-ui">Read a notice</b></div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><em>Issue a refund:</em> <b class="gd-ui">Request the refund</b>, <b class="gd-ui">Issue the refund</b></div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><em>Schedule a field job:</em> <b class="gd-ui">Field jobs</b> &gt; <b class="gd-ui">Schedule</b></div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t"><em>Cover a plate:</em> <b class="gd-ui">Cover the plate</b>, <b class="gd-ui">Save the covered photo</b></div></li></ol></div><h3 class="gd-h3">If something goes wrong</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">What you see</th><th scope="col">What to do</th></tr></thead><tbody><tr><td><b class="gd-ui">A link says it expired</b></td><td>Links in our emails work for 24 hours, once. Press <b class="gd-ui">Send me a new link</b> on that page.</td></tr><tr><td><b class="gd-ui">&quot;Error 1102&quot; on a page</b></td><td>A short limit on our web host. Reload the page. You are still signed in.</td></tr><tr><td><b class="gd-ui">&quot;That email and password do not match an account.&quot;</b></td><td>Check the address, or use <b class="gd-ui">Set a new password</b> on the sign-in page.</td></tr><tr><td><b class="gd-ui">A task is above your limit</b></td><td>Press <b class="gd-ui">Escalate</b> and say why. An Admin picks it up.</td></tr><tr><td><b class="gd-ui">Asked for a 6-digit code</b></td><td>Open your authenticator app. Lost your phone? Tell an Admin.</td></tr></tbody></table></div>');
select app.guide_release_section('field', 'quick-reference', 'reference', 'report-referrals-and-profile', '### Where things are

| Item | What it is for |
| --- | --- |
| **My jobs** | Today and Tomorrow, in order; Vehicle moves |
| **A job** | Open in maps, Acknowledge, Start |
| **Report** | Damage, warning light, collision, ticket, lost property |
| **Referrals** | Your link and QR code |
| **Profile** | Phone, two-step sign-in, password, Sign out |

### Top tasks

1. **Start a job** **Open the job**, **Acknowledge**, **Start**
2. **Hand over a car** Every step, then **Hand over the keys**
3. **Stop a handover** **Stop: do not release the car**, call us
4. **Take a car back** Every step, then **Complete the return**
5. **Shoot listing photos** **Take photo**, then **Submit for listing**
6. **Move a car** **Start a move**, then **End the move**
7. **Report an incident** ›*Send the report

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **A photo did not upload** | Check your signal, then press **Send again**. |
| **The renter does not match** | Do not hand over. Press Stop and call us. |
', 'Quick reference', 'One page with the essentials.',
  '### Where things are

| Item | What it is for |
| --- | --- |
| **My jobs** | Today and Tomorrow, in order; Vehicle moves |
| **A job** | Open in maps, Acknowledge, Start |
| **Report** | Damage, warning light, collision, ticket, lost property |
| **Referrals** | Your link and QR code |
| **Profile** | Phone, two-step sign-in, password, Sign out |

### Top tasks

1. *Start a job:* **Open the job**, **Acknowledge**, **Start**
2. *Hand over a car:* Every step, then **Hand over the keys**
3. *Stop a handover:* **Stop: do not release the car**, call us
4. *Take a car back:* Every step, then **Complete the return**
5. *Shoot listing photos:* **Take photo**, then **Submit for listing**
6. *Move a car:* **Start a move**, then **End the move**
7. *Report an incident:* **Report** > **Send the report**

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **A photo did not upload** | Check your signal, then press **Send again**. |
| **The renter does not match** | Do not hand over. Press Stop and call us. |
',
  '<h3 class="gd-h3">Where things are</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Item</th><th scope="col">What it is for</th></tr></thead><tbody><tr><td><b class="gd-ui">My jobs</b></td><td>Today and Tomorrow, in order; Vehicle moves</td></tr><tr><td><b class="gd-ui">A job</b></td><td>Open in maps, Acknowledge, Start</td></tr><tr><td><b class="gd-ui">Report</b></td><td>Damage, warning light, collision, ticket, lost property</td></tr><tr><td><b class="gd-ui">Referrals</b></td><td>Your link and QR code</td></tr><tr><td><b class="gd-ui">Profile</b></td><td>Phone, two-step sign-in, password, Sign out</td></tr></tbody></table></div><h3 class="gd-h3">Top tasks</h3><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><em>Start a job:</em> <b class="gd-ui">Open the job</b>, <b class="gd-ui">Acknowledge</b>, <b class="gd-ui">Start</b></div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><em>Hand over a car:</em> Every step, then <b class="gd-ui">Hand over the keys</b></div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><em>Stop a handover:</em> <b class="gd-ui">Stop: do not release the car</b>, call us</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><em>Take a car back:</em> Every step, then <b class="gd-ui">Complete the return</b></div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><em>Shoot listing photos:</em> <b class="gd-ui">Take photo</b>, then <b class="gd-ui">Submit for listing</b></div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><em>Move a car:</em> <b class="gd-ui">Start a move</b>, then <b class="gd-ui">End the move</b></div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><em>Report an incident:</em> <b class="gd-ui">Report</b> &gt; <b class="gd-ui">Send the report</b></div></li></ol></div><h3 class="gd-h3">If something goes wrong</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">What you see</th><th scope="col">What to do</th></tr></thead><tbody><tr><td><b class="gd-ui">A link says it expired</b></td><td>Links in our emails work for 24 hours, once. Press <b class="gd-ui">Send me a new link</b> on that page.</td></tr><tr><td><b class="gd-ui">&quot;Error 1102&quot; on a page</b></td><td>A short limit on our web host. Reload the page. You are still signed in.</td></tr><tr><td><b class="gd-ui">&quot;That email and password do not match an account.&quot;</b></td><td>Check the address, or use <b class="gd-ui">Set a new password</b> on the sign-in page.</td></tr><tr><td><b class="gd-ui">A photo did not upload</b></td><td>Check your signal, then press <b class="gd-ui">Send again</b>.</td></tr><tr><td><b class="gd-ui">The renter does not match</b></td><td>Do not hand over. Press Stop and call us.</td></tr></tbody></table></div>');
select app.guide_release_section('investor', 'your-investments', 'chapter', 'start-here', 'Investments shows each of your investments: what you put in, what it earns, and when it pays.

## Read an investment

1. The menu: **Investments**, **Statements** and **Profile and notices**. **Sign out** is on the right.
2. Your agreement number and name.
3. Invested Amount, Principal, what was reinvested and redeemed to date, and the Yearly Percentage.
4. Investment Date, Lockup End Date, how Returns are handled (Paid monthly or Reinvested) and the Next Payment Date.
5. Latest statement, with **Open**.

![](/guides/img/investor-01-investments-phone-d7251016.jpg "phone; size: 390 795; pins: 1 97.0 14.5, 2 76.9 28.3, 3 92.3 37.1, 4 92.3 71.7, 5 92.3 96.2")

> Tip: This area shows your records under your Investment Agreement. It is not an offer or a solicitation.

## Sign your investment agreement

When CarmaCars sends your agreement, it is under Documents to sign.

1. Press **Documents to sign** in the menu. The top shows what is signed ("0 of 1 signed").
2. Check the key values: your name and address, the Invested Amount, the Yearly Percentage and the dates. The agreement is filled in from your record.
3. Press **Read the PDF** and read it, with its schedules.
4. Say whether you got independent legal advice, and tick the risk acknowledgment (Schedule C). Your initials are filled in.
5. Press **Sign**. Your full legal name is your signature (or press **Draw instead**). The signed copy is on the same page.

> Tip: Signed on paper instead? Once we record it, it shows under Signed with the scan.
', 'Your investments', 'Each investment, its returns and the latest statement.',
  'Investments shows each of your investments: what you put in, what it earns, and when it pays.

## Read an investment

1. The menu: **Investments**, **Statements** and **Profile and notices**. **Sign out** is on the right.
2. Your agreement number and name.
3. Invested Amount, Principal, what was reinvested and redeemed to date, and the Yearly Percentage.
4. Investment Date, Lockup End Date, how Returns are handled (Paid monthly or Reinvested) and the Next Payment Date.
5. Latest statement, with **Open**.

![](/guides/img/investor-01-investments-phone-d7251016.jpg "phone; size: 390 795; pins: 1 97.0 14.5, 2 76.9 28.3, 3 92.3 37.1, 4 92.3 71.7, 5 92.3 96.2")

> Tip: This area shows your records under your Investment Agreement. It is not an offer or a solicitation.

## Sign your investment agreement

When CarmaCars sends your agreement, it is under Documents to sign.

1. Press **Documents to sign** in the menu. The top shows what is signed ("0 of 1 signed").
2. Check the key values: your name and address, the Invested Amount, the Yearly Percentage and the dates. The agreement is filled in from your record.
3. Press **Read the PDF** and read it, with its schedules.
4. Say whether you got independent legal advice, and tick the risk acknowledgment (Schedule C). Your initials are filled in.
5. Press **Sign**. Your full legal name is your signature (or press **Draw instead**). The signed copy is on the same page.

Once you sign, the agreement shows "Awaiting countersignature by CarmaCars" under Signed. CarmaCars''s signing officer countersigns it; the agreement binds CarmaCars once it is countersigned and your funds have cleared. You get the countersigned copy on the same page.

> Tip: Signed on paper instead? Once we record it, it shows under Signed with the scan.
',
  '<p class="gd-p">Investments shows each of your investments: what you put in, what it earns, and when it pays.</p><section class="gd-task" id="your-investments-read-an-investment" data-gd-task><h2 class="gd-h2">Read an investment</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The menu: <b class="gd-ui">Investments</b>, <b class="gd-ui">Statements</b> and <b class="gd-ui">Profile and notices</b>. <b class="gd-ui">Sign out</b> is on the right.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Your agreement number and name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Invested Amount, Principal, what was reinvested and redeemed to date, and the Yearly Percentage.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Investment Date, Lockup End Date, how Returns are handled (Paid monthly or Reinvested) and the Next Payment Date.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Latest statement, with <b class="gd-ui">Open</b>.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/795"><img src="/guides/img/investor-01-investments-phone-d7251016.jpg" alt="" loading="lazy" decoding="async" width="390" height="795"><span class="gd-pin" style="left:97%;top:14.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:76.9%;top:28.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:92.3%;top:37.1%" aria-hidden="true">3</span><span class="gd-pin" style="left:92.3%;top:71.7%" aria-hidden="true">4</span><span class="gd-pin" style="left:92.3%;top:96.2%" aria-hidden="true">5</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>This area shows your records under your Investment Agreement. It is not an offer or a solicitation.</div></aside></section><section class="gd-task" id="your-investments-sign-your-investment-agreement" data-gd-task><h2 class="gd-h2">Sign your investment agreement</h2><p class="gd-p">When CarmaCars sends your agreement, it is under Documents to sign.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Documents to sign</b> in the menu. The top shows what is signed (&quot;0 of 1 signed&quot;).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the key values: your name and address, the Invested Amount, the Yearly Percentage and the dates. The agreement is filled in from your record.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Read the PDF</b> and read it, with its schedules.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Say whether you got independent legal advice, and tick the risk acknowledgment (Schedule C). Your initials are filled in.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Sign</b>. Your full legal name is your signature (or press <b class="gd-ui">Draw instead</b>). The signed copy is on the same page.</div></li></ol></div><p class="gd-p">Once you sign, the agreement shows &quot;Awaiting countersignature by CarmaCars&quot; under Signed. CarmaCars&#39;s signing officer countersigns it; the agreement binds CarmaCars once it is countersigned and your funds have cleared. You get the countersigned copy on the same page.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Signed on paper instead? Once we record it, it shows under Signed with the scan.</div></aside></section>');
select app.guide_release_section('investor', 'quick-reference', 'reference', 'keeping-your-account-safe', '### Where things are

| Item | What it is for |
| --- | --- |
| **Investments** | Each investment, returns, next payment |
| **Statements** | One per month; PDF, ZIP and CSV by year |
| **Profile and notices** | Contact details, notices, transfers, two-step sign-in |

### Top tasks

1. **See what you earned** ›*a month
2. **Keep a statement** **Download PDF**
3. **A whole year** ›*Download a year
4. **Paid monthly or reinvested** **Send the notice**
5. **Change your bank account** **Ask to change the bank account**
6. **Transfer an investment** **Send the request**
7. **Protect your account** **Set up two-step sign-in**

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **Asked for a 6-digit code** | Open your authenticator app. Lost your phone? Call us. |
', 'Quick reference', 'One page with the essentials.',
  '### Where things are

| Item | What it is for |
| --- | --- |
| **Investments** | Each investment, returns, next payment |
| **Statements** | One per month; PDF, ZIP and CSV by year |
| **Profile and notices** | Contact details, notices, transfers, two-step sign-in |

### Top tasks

1. *See what you earned:* **Statements**, then a month
2. *Keep a statement:* **Download PDF**
3. *A whole year:* **Statements** > **Download a year**
4. *Paid monthly or reinvested:* **Send the notice**
5. *Change your bank account:* **Ask to change the bank account**
6. *Transfer an investment:* **Send the request**
7. *Protect your account:* **Set up two-step sign-in**

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **Asked for a 6-digit code** | Open your authenticator app. Lost your phone? Call us. |
',
  '<h3 class="gd-h3">Where things are</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Item</th><th scope="col">What it is for</th></tr></thead><tbody><tr><td><b class="gd-ui">Investments</b></td><td>Each investment, returns, next payment</td></tr><tr><td><b class="gd-ui">Statements</b></td><td>One per month; PDF, ZIP and CSV by year</td></tr><tr><td><b class="gd-ui">Profile and notices</b></td><td>Contact details, notices, transfers, two-step sign-in</td></tr></tbody></table></div><h3 class="gd-h3">Top tasks</h3><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><em>See what you earned:</em> <b class="gd-ui">Statements</b>, then a month</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><em>Keep a statement:</em> <b class="gd-ui">Download PDF</b></div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><em>A whole year:</em> <b class="gd-ui">Statements</b> &gt; <b class="gd-ui">Download a year</b></div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><em>Paid monthly or reinvested:</em> <b class="gd-ui">Send the notice</b></div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><em>Change your bank account:</em> <b class="gd-ui">Ask to change the bank account</b></div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><em>Transfer an investment:</em> <b class="gd-ui">Send the request</b></div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><em>Protect your account:</em> <b class="gd-ui">Set up two-step sign-in</b></div></li></ol></div><h3 class="gd-h3">If something goes wrong</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">What you see</th><th scope="col">What to do</th></tr></thead><tbody><tr><td><b class="gd-ui">A link says it expired</b></td><td>Links in our emails work for 24 hours, once. Press <b class="gd-ui">Send me a new link</b> on that page.</td></tr><tr><td><b class="gd-ui">&quot;Error 1102&quot; on a page</b></td><td>A short limit on our web host. Reload the page. You are still signed in.</td></tr><tr><td><b class="gd-ui">&quot;That email and password do not match an account.&quot;</b></td><td>Check the address, or use <b class="gd-ui">Set a new password</b> on the sign-in page.</td></tr><tr><td><b class="gd-ui">Asked for a 6-digit code</b></td><td>Open your authenticator app. Lost your phone? Call us.</td></tr></tbody></table></div>');
-- GUIDES 0055 END

select app.attach_audit();
