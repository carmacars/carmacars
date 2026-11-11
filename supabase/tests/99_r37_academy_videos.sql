-- 99: release 37 (migration 2301): the academy's lessons as real video files. Who reads and saves a lesson's video
-- (whoever may watch the lesson), the folder and type, one current video a lesson, a changed lesson makes its video stale,
-- and the Admin's list and removal. Fixtures start with "r37v"; addresses are example.test.
select test.suite('99 r37 academy videos (2301)');

select test.mk_user('r37v_admin', 'admin');
select test.mk_user('r37v_cs', 'va', 'cs');
select test.mk_user('r37v_renter', 'renter');
create function pg_temp.dr(p_user text, p_call text, p_name text, p jsonb) returns jsonb language sql as
$$ select public.door(test.id(p_user), 'aal2', p_call, p_name, p) $$;
-- the first lesson of customer service's first section (open to them), and a lesson of a later section (not open yet)
create temp table r37l as
  select (select l.id from academy_path_sections ps join academy_lessons l on l.section_id = ps.section_id where ps.path_code = 'cs' order by ps.sort, l.sort limit 1) first_l,
         (select l.id from academy_path_sections ps join academy_lessons l on l.section_id = ps.section_id where ps.path_code = 'cs' order by ps.sort desc, l.sort limit 1) later_l;
create function pg_temp.p(p_lesson uuid, p_ext text default 'mp4') returns jsonb language sql as
$$ select jsonb_build_object('lesson', p_lesson, 'path', 'academy/videos/' || p_lesson || '/' || gen_random_uuid() || '.' || p_ext,
     'mime', 'video/' || p_ext, 'seconds', 64.5, 'bytes', 3000000) $$;

select test.eq('staff read the lesson they may watch: no video yet', (select pg_temp.dr('r37v_cs', 'ops_read', 'academy_videos', jsonb_build_object('lesson', first_l)) #> '{lessons,0,video}' from r37l), 'null'::jsonb);
select test.throws('not a lesson of a later section', (select format($$select pg_temp.dr('r37v_cs', 'ops_read', 'academy_videos', jsonb_build_object('lesson', %L))$$, later_l) from r37l), 'Pass the section');
select test.throws('staff do not list every lesson (the Admin renders them)', $$select pg_temp.dr('r37v_cs', 'ops_read', 'academy_videos', '{}'::jsonb)$$, 'An Admin renders');
select test.throws('a renter cannot', (select format($$select pg_temp.dr('r37v_renter', 'ops_read', 'academy_videos', jsonb_build_object('lesson', %L))$$, first_l) from r37l), null);
select test.throws('a file outside the lesson''s folder is refused', (select format($$select pg_temp.dr('r37v_cs', 'ops_do', 'academy_video_save', jsonb_build_object('lesson', %L, 'path', 'academy/videos/x/a.mp4', 'mime', 'video/mp4', 'seconds', 5, 'bytes', 10))$$, first_l) from r37l), 'folder');
select test.throws('only MP4 or WebM', (select format($$select pg_temp.dr('r37v_cs', 'ops_do', 'academy_video_save', pg_temp.p(%L) || jsonb_build_object('mime', 'video/quicktime'))$$, first_l) from r37l), 'check');
create temp table r37s as select pg_temp.dr('r37v_cs', 'ops_do', 'academy_video_save', pg_temp.p(first_l)) r from r37l;
select test.ok('staff save the recording: it is the lesson''s current video', (select (r ->> 'saved') is not null and r #>> '{lessons,0,video,mime}' = 'video/mp4' from r37s));
select test.eq('a second recording of the same scenes is not kept', (select pg_temp.dr('r37v_admin', 'ops_do', 'academy_video_save', pg_temp.p(first_l, 'webm')) ->> 'kept' from r37l), 'existing');
select test.eq('one row', (select count(*)::int from academy_lesson_videos where lesson_id = (select first_l from r37l) and removed_at is null), 1);
update academy_lessons set scenes = scenes || jsonb_build_array(jsonb_build_object('caption', 'New rule', 'say', 'A new rule.', 'visual', jsonb_build_object('kind', 'title', 'heading', 'New'))) where id = (select first_l from r37l);
select test.eq('the lesson changed: its video is stale and not offered', (select pg_temp.dr('r37v_cs', 'ops_read', 'academy_videos', jsonb_build_object('lesson', first_l)) #> '{lessons,0,video}' from r37l), 'null'::jsonb);
select test.ok('the Admin lists every lesson with or without a video', (select jsonb_array_length(pg_temp.dr('r37v_admin', 'ops_read', 'academy_videos', '{}'::jsonb) -> 'lessons') = (select count(*) from academy_lessons where jsonb_array_length(scenes) > 0)));
create temp table r37n as select pg_temp.dr('r37v_admin', 'ops_do', 'academy_video_save', pg_temp.p(first_l, 'webm')) r from r37l;
select test.ok('a new recording of the changed lesson is saved', (select (r ->> 'saved') is not null from r37n));
select test.throws('staff do not remove videos', (select format($$select pg_temp.dr('r37v_cs', 'ops_do', 'academy_video_remove', jsonb_build_object('id', %L))$$, r ->> 'saved') from r37n), 'An Admin removes');
select test.ok('the Admin removes it (its file path is returned for deletion)', (select pg_temp.dr('r37v_admin', 'ops_do', 'academy_video_remove', jsonb_build_object('id', r ->> 'saved')) ->> 'removed_path' like 'academy/videos/%' from r37n));
select test.ok('the table is closed to signed-in users', not has_table_privilege('authenticated', 'academy_lesson_videos', 'select'));
