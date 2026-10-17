-- 35: the guides keep up with the portals by themselves (migration 0055): the runs and their commit, the sections the run
-- reads, an automatic change published or kept as a suggestion, the one-click revert, the admin reads, new chapters.
-- Fixtures start with "gk".
select test.suite('35 guides keep up');
create table test.gk (k text primary key, v jsonb);
create function test.gk_do(p_user text, p_name text, p jsonb) returns jsonb language sql as $$ select public.door(test.id(p_user), null, 'ops_do', p_name, p) $$;
create function test.gk_read(p_user text, p_name text, p jsonb default '{}') returns jsonb language sql as $$ select public.door(test.id(p_user), null, 'ops_read', p_name, p) $$;
select test.mk_user('gk_admin', 'admin');
select test.mk_user('gk_cs', 'va', 'cs');

insert into guides (portal, title, signin_url) values ('field', 'Field guide', '/field') on conflict (portal) do nothing;
update guides set version = 7, published_at = now() - interval '2 days' where portal = 'field';
insert into guide_sections (id, portal, kind, sort_order, slug, title, body_md, draft_version, published_title, published_md, published_html, published_hidden, published_version, published_at)
values (test.id('gs:gk1'), 'field', 'chapter', 950, 'gk-jobs', 'Gk jobs', E'1. Press **Start the job**.\n\n![](/guides/img/field-01-jobs-phone-aaaa.jpg "phone")\n', 3,
        'Gk jobs', E'1. Press **Start the job**.\n\n![](/guides/img/field-01-jobs-phone-aaaa.jpg "phone")\n', '<p>Old</p>', false, 3, now() - interval '2 days'),
       (test.id('gs:gk2'), 'field', 'chapter', 951, 'gk-drafted', 'Gk drafted', E'My draft words.\n', 2,
        'Gk drafted', E'Published words.\n', '<p>Published words.</p>', false, 1, now() - interval '2 days');

-- ================================================================ 1. the runs
select test.eq('runs: no finished run yet, so the first run after a deploy does the whole check', coalesce(public.server_guide_upkeep_last_sha(), 'none'), 'none');
select public.server_guide_upkeep_run('{"run": "gk-1", "sha": "aaaaaaa1", "status": "started"}');
select test.eq('runs: a run that has not finished does not count', coalesce(public.server_guide_upkeep_last_sha(), 'none'), 'none');
select public.server_guide_upkeep_run('{"run": "gk-1", "sha": "aaaaaaa1", "status": "done", "images": 2, "sections_rewritten": 1, "pdfs": 1}');
select test.eq('runs: the commit of the last finished run, for the next one to compare with', public.server_guide_upkeep_last_sha(), 'aaaaaaa1');
select public.server_guide_upkeep_run('{"run": "gk-2", "sha": "bbbbbbb2", "status": "failed"}');
select test.eq('runs: a failed run leaves the last good commit', public.server_guide_upkeep_last_sha(), 'aaaaaaa1');
select test.eq('runs: one row per run, its counts kept', (select images || '/' || sections_rewritten || '/' || pdfs || '/' || status from guide_upkeep_runs where run = 'gk-1'), '2/1/1/done');
select test.eq('runs: Admin > Settings > Guides lists them, newest first', (test.gk_read('gk_admin', 'guide_upkeep_runs') -> 0 ->> 'run'), 'gk-2');
select test.throws('runs: for Admins only', $$select test.gk_read('gk_cs', 'guide_upkeep_runs')$$, null);
select test.throws('runs: not for the site''s visitors', $$set local role anon; select public.server_guide_upkeep_last_sha()$$, 'permission denied');

-- ================================================================ 2. the sections the run reads
update guide_sections set needs_review = true, review_images = jsonb_build_array(jsonb_build_object('old_url', '/x.jpg', 'new_url', '/y.jpg', 'run', 'gk-3')) where id = test.id('gs:gk1');
insert into test.gk select 'secs', public.server_guide_upkeep_sections('gk-3');
select test.eq('sections: the published text, with the screenshots this run replaced',
  (select (s ->> 'body_md' like '%Start the job%')::text || '/' || jsonb_array_length(s -> 'images_changed') || '/' || (s ->> 'draft_waiting')
     from jsonb_array_elements((select v from test.gk where k = 'secs')) s where s ->> 'slug' = 'gk-jobs'), 'true/1/false');
select test.eq('sections: an Admin''s draft waiting is said',
  (select s ->> 'draft_waiting' from jsonb_array_elements((select v from test.gk where k = 'secs')) s where s ->> 'slug' = 'gk-drafted'), 'true');
select test.eq('sections: another run''s screenshots are not this run''s',
  (select jsonb_array_length(s -> 'images_changed') from jsonb_array_elements(public.server_guide_upkeep_sections('gk-4')) s where s ->> 'slug' = 'gk-jobs'), 0);

-- ================================================================ 3. the automatic change
insert into test.gk select 'up1', public.server_guide_auto_update(jsonb_build_object('section_id', test.id('gs:gk1'), 'run', 'gk-3', 'model', '@cf/meta/llama-3.3-70b-instruct-fp8-fast',
  'reason', 'It names buttons the portals no longer show (Start the job)', 'checks_ok', true, 'neurons', 410,
  'body_md', E'1. Press **Start**.\n\n![](/guides/img/field-01-jobs-phone-aaaa.jpg "phone")\n', 'html', '<p>New</p>'));
select test.eq('auto: a rewrite that passed the checks is published at once', (select v ->> 'result' from test.gk where k = 'up1'), 'updated');
select test.eq('auto: the draft and the published copy carry it, as a new version',
  (select (body_md like '%**Start**.%')::text || '/' || (published_md = body_md) || '/' || published_html || '/' || draft_version || '/' || published_version
     from guide_sections where id = test.id('gs:gk1')), 'true/true/<p>New</p>/4/4');
select test.eq('auto: the text it replaced is kept for the revert, with when and why',
  (select (auto_prev ->> 'published_md' like '%Start the job%')::text || '/' || (auto_updated_at is not null) || '/' || auto_update_run || '/' || (auto_update_reason like 'It names buttons%')
     from guide_sections where id = test.id('gs:gk1')), 'true/true/gk-3/true');
select test.eq('auto: the review flag is cleared', (select needs_review from guide_sections where id = test.id('gs:gk1')), false);
select test.eq('auto: the history has the new version, draft and published', (select count(*) from guide_section_versions where section_id = test.id('gs:gk1') and version = 4), 2);
select test.eq('auto: the guide gets a new version (its PDF shows as older)', (select version from guides where portal = 'field'), 8);
select test.eq('auto: the model call is recorded with its neurons', (select units from provider_calls where purpose = 'guide_rewrite' order by created_at desc limit 1), 410);
-- a second section of the same run keeps the guide's version
insert into guide_sections (id, portal, kind, sort_order, slug, title, body_md, draft_version, published_title, published_md, published_html, published_hidden, published_version, published_at)
values (test.id('gs:gk3'), 'field', 'chapter', 952, 'gk-more', 'Gk more', E'Press **Old button**.\n', 1, 'Gk more', E'Press **Old button**.\n', '<p>x</p>', false, 1, now());
select public.server_guide_auto_update(jsonb_build_object('section_id', test.id('gs:gk3'), 'run', 'gk-3', 'checks_ok', true, 'body_md', E'Press **New button**.\n', 'html', '<p>y</p>'));
select test.eq('auto: one new guide version per run', (select version from guides where portal = 'field'), 8);

-- held back
select test.eq('auto: a rewrite that failed the checks waits as a suggestion',
  public.server_guide_auto_update(jsonb_build_object('section_id', test.id('gs:gk3'), 'run', 'gk-5', 'checks_ok', false, 'problems', 'an em dash',
    'body_md', E'Press **New button** now.\n', 'html', '<p>z</p>')) ->> 'result', 'suggested');
select test.eq('auto: the published text is untouched, the reason is said',
  (select (published_md = E'Press **New button**.\n')::text || '/' || needs_review || '/' || (suggestion_md like '%now.%') || '/' || (review_note like '%did not pass the checks (an em dash)%')
     from guide_sections where id = test.id('gs:gk3')), 'true/true/true/true');
select test.eq('auto: an Admin''s draft waiting is never overwritten',
  public.server_guide_auto_update(jsonb_build_object('section_id', test.id('gs:gk2'), 'run', 'gk-5', 'checks_ok', true, 'body_md', E'Robot words here.\n', 'html', '<p>r</p>')) ->> 'result', 'suggested');
select test.eq('auto: the draft and the published copy stay as they were',
  (select body_md || '|' || published_md || '|' || (review_note like '%draft is waiting%') from guide_sections where id = test.id('gs:gk2')), E'My draft words.\n|Published words.\n|true');
select test.eq('auto: the same text again changes nothing',
  public.server_guide_auto_update(jsonb_build_object('section_id', test.id('gs:gk1'), 'run', 'gk-6', 'checks_ok', true,
    'body_md', E'1. Press **Start**.\n\n![](/guides/img/field-01-jobs-phone-aaaa.jpg "phone")\n', 'html', '<p>New</p>')) ->> 'result', 'same');
select test.throws('auto: the server''s own call, not the visitors''', $$set local role authenticated; select public.server_guide_auto_update('{}')$$, 'permission denied');

-- ================================================================ 4. what Admins see, and the revert
insert into test.gk select 'ga', test.gk_read('gk_admin', 'guide_admin', '{"portal": "field"}');
select test.eq('admin: the section says when it changed automatically, and that it can be reverted',
  (select (s ->> 'auto_updated_at' is not null)::text || '/' || (s ->> 'can_revert') || '/' || (s ->> 'auto_update_reason' like 'It names%')
     from jsonb_array_elements((select v from test.gk where k = 'ga') -> 'sections') s where s ->> 'slug' = 'gk-jobs'), 'true/true/true');
select test.eq('admin: the guide shows its last run', (select v -> 'last_run' ->> 'run' from test.gk where k = 'ga'), 'gk-2');
select test.eq('admin: the list of guides counts the sections changed automatically',
  (select g ->> 'auto_updated' from jsonb_array_elements(test.gk_read('gk_admin', 'guides_admin')) g where g ->> 'portal' = 'field'), '2');
select test.throws('revert: an Admin only', format($$select test.gk_do('gk_cs', 'guide_auto_revert', jsonb_build_object('id', %L))$$, test.id('gs:gk1')), null);
insert into test.gk select 'rv', test.gk_do('gk_admin', 'guide_auto_revert', jsonb_build_object('id', test.id('gs:gk1')));
select test.eq('revert: one click brings back the text it replaced, published, as a new version',
  (select (published_md like '%Start the job%')::text || '/' || (body_md = published_md) || '/' || published_html || '/' || draft_version || '/' || published_version || '/' || (auto_prev is null) || '/' || (auto_updated_at is null)
     from guide_sections where id = test.id('gs:gk1')), 'true/true/<p>Old</p>/5/5/true/true');
select test.eq('revert: the history keeps both texts', (select count(distinct body_md) from guide_section_versions where section_id = test.id('gs:gk1')), 2);
select test.ok('revert: it is in the audit log', exists (select 1 from audit_log where action = 'guide_auto_revert' and entity_id = test.id('gs:gk1')::text));
select test.throws('revert: nothing to undo twice', format($$select test.gk_do('gk_admin', 'guide_auto_revert', jsonb_build_object('id', %L))$$, test.id('gs:gk1')), 'no automatic change to undo');

-- ================================================================ 5. new chapters of a release
select test.eq('new chapter: added after the one named, published',
  app.guide_add_published_section('field', 'gk-new', 'chapter', 'gk-jobs', 'Gk new', 'A new chapter.', E'New **Start**.\n', '<p>new</p>'), 'added');
select test.eq('new chapter: in place, version 1 published',
  (select (sort_order = (select sort_order + 1 from guide_sections where slug = 'gk-jobs' and portal = 'field'))::text || '/' || published_version || '/' || published_html
     from guide_sections where portal = 'field' and slug = 'gk-new'), 'true/1/<p>new</p>');
select test.eq('new chapter: one that exists is left alone', app.guide_add_published_section('field', 'gk-new', 'chapter', null, 'Again', null, 'x', 'x'), 'exists');

-- ================================================================ 6. this release's chapters
insert into guide_images (portal, url, alt, replaces_url) values ('field', 'https://photos.example.test/guides/field/upkeep-gk.jpg', 'x', '/guides/img/gk-shot.jpg');
insert into guide_sections (portal, kind, sort_order, slug, title, body_md, draft_version, published_title, published_md, published_html, published_hidden, published_version, published_at)
values ('field', 'chapter', 960, 'gk-rel', 'Gk rel', E'Old ![](https://photos.example.test/guides/field/upkeep-gk.jpg "phone")\n', 1, 'Gk rel',
        E'Old ![](https://photos.example.test/guides/field/upkeep-gk.jpg "phone")\n', '<img src="https://photos.example.test/guides/field/upkeep-gk.jpg">', false, 1, now());
select test.eq('release: a chapter still showing our text (with the screenshot the upkeep replaced) gets the new one',
  app.guide_release_section('field', 'gk-rel', 'chapter', null, E'Old ![](/guides/img/gk-shot.jpg "phone")\n', 'Gk rel', null, E'New ![](/guides/img/gk-shot.jpg "phone")\n',
                            '<p>New</p><img src="/guides/img/gk-shot.jpg">'), 'updated');
select test.eq('release: the new text keeps the newer screenshot, never the older committed one',
  (select (published_md = E'New ![](https://photos.example.test/guides/field/upkeep-gk.jpg "phone")\n')::text || '/' || (published_html like '%upkeep-gk.jpg%') || '/' || (body_md = published_md)
     from guide_sections where portal = 'field' and slug = 'gk-rel'), 'true/true/true');
select test.eq('release: the same again changes nothing',
  app.guide_release_section('field', 'gk-rel', 'chapter', null, E'Old\n', 'Gk rel', null, E'New ![](/guides/img/gk-shot.jpg "phone")\n', '<p>New</p><img src="/guides/img/gk-shot.jpg">'), 'same');
select test.eq('release: a chapter an Admin edited keeps the Admin''s text and gets a suggestion',
  app.guide_release_section('field', 'gk-drafted', 'chapter', null, E'Published words.\n', 'Gk drafted', null, E'Our new words.\n', '<p>Our new words.</p>'), 'suggested');
select test.eq('release: a guide with no chapters yet waits for the seed', app.guide_release_section('investor', 'gk-none', 'chapter', null, null, 'X', null, 'X', 'X'),
  (select case when exists (select 1 from guide_sections where portal = 'investor') then 'added' else 'missing' end));

