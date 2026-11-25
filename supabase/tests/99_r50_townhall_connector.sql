-- 99: the townhall in the Admin connector (migration 4500): townhall_status (next meeting, call link, this week's deck, the staff on it
-- and missing from it, reminders, field-call slots), townhall_set_call_url (https only, preview then confirm) and
-- townhall_rebuild_deck (preview then confirm, the notes kept). Fixtures start with "th5".
select test.suite('99 r50 townhall connector');
create temp table th5_ps as select id, api_access_enabled e, api_calls_per_minute n, townhall_call_url u from program_settings;
update program_settings set api_access_enabled = true, api_calls_per_minute = 600 where id is not null;
select test.mk_user('th5_admin', 'admin');
select test.mk_user('th5_cs', 'va', 'cs');
create function test.th5_h(p text) returns text language sql as $$ select encode(sha256(convert_to(p, 'UTF8')), 'hex') $$;
select app.api_key_create(test.id('th5_admin'), test.id('th5_admin'), 'Laptop', array['admin:read', 'admin:write'], test.th5_h('cc_live_th5_full'), 'cc_live_th5_');
select app.api_key_create(test.id('th5_admin'), test.id('th5_admin'), 'Read', array['admin:read'], test.th5_h('cc_live_th5_read'), 'cc_live_th5r');
insert into api_keys (user_id, kind, name, prefix, key_hash, scopes, created_by)
select test.id('th5_cs'), kind, 'Not allowed', 'cc_live_th5c', test.th5_h('cc_live_th5_cs'), scopes, test.id('th5_admin') from api_keys where key_hash = test.th5_h('cc_live_th5_full');
create function test.th5(p_key text, p_tool text, a jsonb) returns jsonb language sql as $$ select app.api_call(test.th5_h(p_key), p_tool, a, 'test') $$;
create function test.th5_do(p_key text, p_tool text, a jsonb) returns jsonb language plpgsql as $$
declare pv jsonb := test.th5(p_key, p_tool, a);
begin
  if not (pv ->> 'ok')::boolean then return pv; end if;
  return test.th5(p_key, p_tool, a || jsonb_build_object('confirm', true, 'preview_id', pv #>> '{result,preview_id}'));
end $$;
delete from townhall_decks where week_of = (date_trunc('week', app.today()::timestamp))::date;

-- ================================================================ who may
select test.eq('a key of a person who is not an Admin is refused', test.th5('cc_live_th5_cs', 'townhall_status', '{}') ->> 'status', '403');
select test.eq('a read key cannot set the link', test.th5('cc_live_th5_read', 'townhall_set_call_url', '{"url": "https://meet.example.test/a"}') ->> 'ok', 'false');
select test.eq('a read key reads the status', test.th5('cc_live_th5_read', 'townhall_status', '{}') ->> 'ok', 'true');

-- ================================================================ status without a deck
select test.eq('no deck yet: not built, staff lists empty', (select (r ->> 'deck_built') || '/' || coalesce(r ->> 'staff_missing', 'null') from (select test.th5('cc_live_th5_full', 'townhall_status', '{}') #> '{result}' r) z), 'false/null');
select test.ok('the next meeting is given in Toronto time', (test.th5('cc_live_th5_full', 'townhall_status', '{}') #>> '{result,next_toronto}') like '%:%');
select test.eq('four reminder steps are listed', jsonb_array_length(test.th5('cc_live_th5_full', 'townhall_status', '{}') #> '{result,reminders}'), 4);

-- ================================================================ the link
select test.eq('http is refused', test.th5('cc_live_th5_full', 'townhall_set_call_url', '{"url": "http://meet.example.test/a"}') ->> 'ok', 'false');
select test.eq('no link is refused', test.th5('cc_live_th5_full', 'townhall_set_call_url', '{}') ->> 'ok', 'false');
select test.eq('a confirm without its preview is refused', test.th5('cc_live_th5_full', 'townhall_set_call_url', '{"url": "https://meet.example.test/a", "confirm": true}') ->> 'ok', 'false');
select test.eq('the preview says what changes', (select (r ->> 'preview') || '/' || (r ->> 'to') from (select test.th5('cc_live_th5_full', 'townhall_set_call_url', '{"url": "https://meet.example.test/a"}') #> '{result}' r) z), 'true/https://meet.example.test/a');
select test.ok('the preview changed nothing', coalesce((app.settings()).townhall_call_url, '') <> 'https://meet.example.test/a');
select test.eq('confirmed', test.th5_do('cc_live_th5_full', 'townhall_set_call_url', '{"url": "https://meet.example.test/a"}') ->> 'ok', 'true');
select test.eq('the link is set', (app.settings()).townhall_call_url, 'https://meet.example.test/a');
select test.eq('the status shows it', test.th5('cc_live_th5_full', 'townhall_status', '{}') #>> '{result,call_url}', 'https://meet.example.test/a');
select test.ok('a preview is logged, and the confirmed call', (select count(*) from api_calls where tool = 'townhall_set_call_url:preview') >= 1 and (select count(*) from api_calls where tool = 'townhall_set_call_url' and ok) >= 1);
select test.eq('the preview was used once', (select count(*) from api_previews where tool = 'townhall_set_call_url' and used_at is not null), 1::bigint);

-- ================================================================ the deck
select test.eq('rebuild preview: no deck yet', (select (r ->> 'preview') || '/' || (r ->> 'deck_built') from (select test.th5('cc_live_th5_full', 'townhall_rebuild_deck', '{}') #> '{result}' r) z), 'true/false');
select test.ok('the preview built nothing', not exists (select 1 from townhall_decks where week_of = (date_trunc('week', app.today()::timestamp))::date));
select test.eq('rebuilt', test.th5_do('cc_live_th5_full', 'townhall_rebuild_deck', '{}') ->> 'ok', 'true');
select test.ok('the deck is built, with its slides', (test.th5('cc_live_th5_full', 'townhall_status', '{}') #>> '{result,deck_built}') = 'true'
  and (test.th5('cc_live_th5_full', 'townhall_status', '{}') #>> '{result,deck,slide_count}')::int > 5);
select test.eq('the staff member is on the deck, nobody missing', (select (r #>> '{staff_missing_count}') || '/' || ((r -> 'staff_featured')::text like '%Th5 Cs%')::text from (select test.th5('cc_live_th5_full', 'townhall_status', '{}') #> '{result}' r) z), '0/true');
update townhall_decks set notes = '{"funnel": "Say well done"}' where week_of = (date_trunc('week', app.today()::timestamp))::date;
select test.mk_user('th5_new', 'va', 'fleet');
select test.eq('a staff member added after the build is missing from the deck', (select (r -> 'staff_missing')::text like '%Th5 New%' from (select test.th5('cc_live_th5_full', 'townhall_status', '{}') #> '{result}' r) z), 'true');
select test.eq('the preview says who is missing and what is kept', (select (r ->> 'notes_kept') || '/' || ((r -> 'staff_missing_now')::text like '%Th5 New%') from (select test.th5('cc_live_th5_full', 'townhall_rebuild_deck', '{}') #> '{result}' r) z), '1/true');
select test.eq('rebuilt again', test.th5_do('cc_live_th5_full', 'townhall_rebuild_deck', '{}') ->> 'ok', 'true');
select test.eq('the new staff member is on the deck now', (select (r #>> '{staff_missing_count}') from (select test.th5('cc_live_th5_full', 'townhall_status', '{}') #> '{result}' r) z), '0');
select test.eq('the notes are kept', (select notes ->> 'funnel' from townhall_decks where week_of = (date_trunc('week', app.today()::timestamp))::date), 'Say well done');
select test.eq('the deck lists its notes', test.th5('cc_live_th5_full', 'townhall_status', '{}') #>> '{result,deck,notes_on,0}', 'funnel');
select test.ok('the rebuild is in the audit log', exists (select 1 from audit_log where action = 'townhall_deck_rebuilt' and actor_user_id = test.id('th5_admin')));

-- ================================================================ privileges
select test.ok('the functions are not open to the public', not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'app' and p.proname in ('townhall_status', 'townhall_set_call_url', 'townhall_rebuild_deck', 'api_call_pre4500') and has_function_privilege('authenticated', p.oid, 'execute')));

update program_settings s set api_access_enabled = p.e, api_calls_per_minute = p.n from th5_ps p where s.id = p.id;
