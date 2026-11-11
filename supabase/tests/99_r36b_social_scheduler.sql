-- 99: release 36b item 3 (migration 2220): the social post scheduler. Who may queue, the channel rules (Instagram needs a
-- photo or an MP4 video, TikTok a video and never through an API), a caption from a draft, the pg_cron job marking posts
-- due, Meta off (a queue posted by hand) and on (claimed by the Worker, posted or retried then failed), and the log.
-- Fixtures start with "rbs"; addresses are example.test.
select test.suite('99 r36b social scheduler (2220)');

select test.mk_user('rbs_admin', 'admin');
select test.mk_user('rbs_sales', 'va', 'sales');
select test.mk_user('rbs_fin', 'va', 'finance');
select test.mk_owner('rbs_olive');
select test.mk_vehicle('rbs_car', 'rbs_olive');
create function pg_temp.v() returns uuid language sql as $$ select test.id('vehicle:rbs_car') $$;
create function pg_temp.dr(p_user text, p_call text, p_name text, p jsonb) returns jsonb language sql as
$$ select public.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;
update meta_publishing set enabled = false, token_ref = null, page_id = null, ig_user_id = null;
insert into social_videos (id, vehicle_id, path, mime, seconds, bytes) values
  ('00000000-0000-4000-8000-0000000000a1', pg_temp.v(), 'vehicles/' || pg_temp.v() || '/social/00000000-0000-4000-8000-0000000000a1.mp4', 'video/mp4', 20, 5000000),
  ('00000000-0000-4000-8000-0000000000a2', pg_temp.v(), 'vehicles/' || pg_temp.v() || '/social/00000000-0000-4000-8000-0000000000a2.webm', 'video/webm', 20, 5000000);
insert into social_drafts (id, slot_date, kind, channels, vehicle_id, caption, link, source)
values ('00000000-0000-4000-8000-0000000000d1', app.today(), 'featured_car', array['instagram', 'facebook_page'], pg_temp.v(), 'Our featured car this week.', 'https://carmacars.ca/cars/rbs', 'staff');

select test.throws('Finance does not schedule posts', $$select pg_temp.dr('rbs_fin', 'ops_read', 'social_queue', '{}')$$, 'Not permitted');
select test.eq('without Meta the queue says it is not connected', (select pg_temp.dr('rbs_sales', 'ops_read', 'social_queue', '{}') #>> '{meta,connected}'), 'false');
select test.throws('a time in the past is refused', $$select pg_temp.dr('rbs_sales', 'ops_do', 'social_queue_add', jsonb_build_object('channel', 'facebook_page', 'caption', 'Hi', 'scheduled_at', now() - interval '1 day'))$$, 'time has passed');
select test.throws('Instagram needs a photo or a video', $$select pg_temp.dr('rbs_sales', 'ops_do', 'social_queue_add', jsonb_build_object('channel', 'instagram', 'caption', 'Hi', 'scheduled_at', now() + interval '1 hour'))$$, 'needs a photo or a video');
select test.throws('Instagram takes MP4 only', $$select pg_temp.dr('rbs_sales', 'ops_do', 'social_queue_add', jsonb_build_object('channel', 'instagram', 'caption', 'Hi', 'video', '00000000-0000-4000-8000-0000000000a2', 'scheduled_at', now() + interval '1 hour'))$$, 'MP4 videos only');
select test.throws('TikTok posts are videos', format($$select pg_temp.dr('rbs_sales', 'ops_do', 'social_queue_add', jsonb_build_object('channel', 'tiktok', 'caption', 'Hi', 'photo', 'vehicles/%s/front.jpg', 'scheduled_at', now() + interval '1 hour'))$$, pg_temp.v()), 'TikTok posts are videos');
select test.throws('a private original is never posted', format($$select pg_temp.dr('rbs_sales', 'ops_do', 'social_queue_add', jsonb_build_object('channel', 'facebook_page', 'caption', 'Hi', 'photo', 'vehicles/%s/original/front.jpg', 'scheduled_at', now() + interval '1 hour'))$$, pg_temp.v()), 'photo on the site');

create temp table rbsq (k text primary key, r jsonb);
insert into rbsq values ('ig', pg_temp.dr('rbs_sales', 'ops_do', 'social_queue_add', jsonb_build_object('channel', 'instagram', 'draft', '00000000-0000-4000-8000-0000000000d1', 'video', '00000000-0000-4000-8000-0000000000a1', 'scheduled_at', now() + interval '1 hour')));
select test.eq('Sales queues an Instagram reel with the draft''s caption and link', (select format('%s|%s|%s|%s', r ->> 'caption', r ->> 'link', r ->> 'media_kind', r ->> 'status') from rbsq where k = 'ig'),
  'Our featured car this week.|https://carmacars.ca/cars/rbs|video|queued');
insert into rbsq values ('tt', pg_temp.dr('rbs_sales', 'ops_do', 'social_queue_add', jsonb_build_object('channel', 'tiktok', 'caption', 'New on CarmaCars', 'video', '00000000-0000-4000-8000-0000000000a2', 'scheduled_at', now())));
insert into rbsq values ('fb', pg_temp.dr('rbs_admin', 'ops_do', 'social_queue_add', jsonb_build_object('channel', 'facebook_page', 'caption', 'Weekend deals', 'scheduled_at', now())));
create function pg_temp.q(p_k text) returns uuid language sql as $$ select (r ->> 'id')::uuid from pg_temp.rbsq where k = p_k $$;

-- the job: the time has come
select test.eq('the job marks the two posts due now (not the one in an hour)', app.job_social_queue(), 2);
select test.eq('statuses', (select string_agg(channel || ' ' || status, ', ' order by channel) from social_queue where id in (pg_temp.q('ig'), pg_temp.q('tt'), pg_temp.q('fb'))),
  'facebook_page due, instagram queued, tiktok due');
select test.ok('the TikTok post is logged as to post by hand', exists (select 1 from social_post_log where queue_id = pg_temp.q('tt') and event = 'due' and detail like '%TikTok by hand%'));
select test.ok('the job is the service''s only (pg_cron runs it every 5 minutes where pg_cron exists)',
  has_function_privilege('service_role', 'app.job_social_queue()', 'execute') and not has_function_privilege('authenticated', 'app.job_social_queue()', 'execute'));
select test.eq('Meta off: nothing for the Worker', public.server_social_queue_claim(), '[]'::jsonb);
select test.eq('Meta off: the Worker''s ads job is not woken for the queue', app.ads_job_due_pre2220() = app.ads_job_due(), true);

-- by hand
select pg_temp.dr('rbs_sales', 'ops_do', 'social_queue_act', jsonb_build_object('id', pg_temp.q('tt'), 'action', 'posted', 'url', 'https://www.tiktok.com/@carmacars/video/1'));
select test.eq('TikTok marked posted by hand, with who and the address', (select format('%s %s %s', status, how, posted_by = test.id('rbs_sales')) from social_queue where id = pg_temp.q('tt')), 'posted hand t');
select test.throws('not posted twice', format($$select pg_temp.dr('rbs_sales', 'ops_do', 'social_queue_act', jsonb_build_object('id', %L, 'action', 'cancel'))$$, pg_temp.q('tt')), 'Only a post not yet posted');
select test.throws('TikTok is never posted through an API', format($$update social_queue set how = 'api' where id = %L$$, pg_temp.q('tt')), 'check');

-- Meta connected: the Worker claims the due Facebook post, Meta refuses twice, then posts
update meta_publishing set enabled = true, token_ref = gen_random_uuid(), page_id = '1234567', ig_user_id = '7654321';
select test.ok('Meta on: the ads job wakes for the due post', app.ads_job_due());
select test.eq('the Worker claims the Facebook post (not TikTok, not the later reel)', (select jsonb_agg(e ->> 'channel') from jsonb_array_elements(public.server_social_queue_claim()) e), '["facebook_page"]'::jsonb);
select test.eq('being posted', (select status from social_queue where id = pg_temp.q('fb')), 'posting');
select public.server_social_queue_result(jsonb_build_object('id', pg_temp.q('fb'), 'ok', false, 'error', 'Meta: (#200) temporary'));
select test.eq('a refusal: due again for another try', (select status || ' ' || attempts from social_queue where id = pg_temp.q('fb')), 'due 1');
select public.server_social_queue_claim();
select public.server_social_queue_result(jsonb_build_object('id', pg_temp.q('fb'), 'ok', true, 'post_id', '1234567_99', 'url', 'https://www.facebook.com/1234567_99'));
select test.eq('posted through Meta with its address', (select format('%s %s %s', status, how, post_url) from social_queue where id = pg_temp.q('fb')), 'posted api https://www.facebook.com/1234567_99');
select test.eq('the log: queued, due, retry, posted', (select string_agg(event, ',' order by at, id) from social_post_log where queue_id = pg_temp.q('fb')), 'queued,due,retry,posted');

-- three refusals: failed, and staff can try again or post it by hand
update social_queue set scheduled_at = now() - interval '1 minute' where id = pg_temp.q('ig');
select public.server_social_queue_claim();
select public.server_social_queue_result(jsonb_build_object('id', pg_temp.q('ig'), 'ok', false, 'error', 'x'));
select public.server_social_queue_claim();
select public.server_social_queue_result(jsonb_build_object('id', pg_temp.q('ig'), 'ok', false, 'error', 'x'));
select public.server_social_queue_claim();
select public.server_social_queue_result(jsonb_build_object('id', pg_temp.q('ig'), 'ok', false, 'error', 'Meta: the video is too short'));
select test.eq('after three refusals: failed with Meta''s answer', (select status || ' ' || error from social_queue where id = pg_temp.q('ig')), 'failed Meta: the video is too short');
select pg_temp.dr('rbs_sales', 'ops_do', 'social_queue_act', jsonb_build_object('id', pg_temp.q('ig'), 'action', 'retry'));
select test.eq('try again: queued with its tries reset', (select status || ' ' || attempts from social_queue where id = pg_temp.q('ig')), 'queued 0');
select pg_temp.dr('rbs_admin', 'ops_do', 'social_queue_act', jsonb_build_object('id', pg_temp.q('ig'), 'action', 'cancel'));
select test.eq('cancelled', (select status from social_queue where id = pg_temp.q('ig')), 'cancelled');
select test.throws('the Worker''s functions are not for signed-in users', $$set local role authenticated; select public.server_social_queue_claim()$$, 'permission denied');
update meta_publishing set enabled = false, token_ref = null, page_id = null, ig_user_id = null;
