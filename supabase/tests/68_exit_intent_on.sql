-- 68: the exit intent game trigger is on again (migration 0101): live, in every settings row, as the column default and
-- in the browser's settings; still an Admin setting that can be turned off.
select test.suite('68 exit intent on');

select test.ok('live: on', (app.settings()).game_exit_intent);
select test.eq('every settings row', (select count(*) from program_settings where not game_exit_intent), 0::bigint);
select test.eq('the column default', (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'game_exit_intent'), 'true');
select test.eq('the browser''s settings', public.game_cfg() ->> 'exit', 'true');
update program_settings set game_exit_intent = false where id = (app.settings()).id;
select test.eq('an Admin can still turn it off', public.game_cfg() ->> 'exit', 'false');
update program_settings set game_exit_intent = true where id = (app.settings()).id;
