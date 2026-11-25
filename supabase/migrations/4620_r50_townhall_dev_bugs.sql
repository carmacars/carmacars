-- 4620: the townhall's "Platform updates" slide shows the bugs staff reported and we fixed (release 50). SCHEMA_MARKER 4620.
-- No applied migration is edited: app.townhall_slides (4600's) is wrapped (townhall_slides_pre4620).
--   * Tech updates: the releases of the week, in plain words, are added by the website from the release notes (model.ts).
--   * Bugs fixed: the staff bug reports (Report a bug, bug_reports) marked fixed in the townhall's week (Toronto days): the count,
--     and a line for each: what was wrong, what was fixed (the Admin's note, else the release), and who reported it (a
--     shout-out). Open bugs (new or triaged, any age) are counted. The slide keeps its 1 minute.
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

-- one short sentence of free text: first line, whitespace collapsed, cut at p_max characters
create function app.th_short(p_text text, p_max int) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select case when length(t) > p_max then rtrim(left(t, p_max - 1)) || '…' else t end
    from (select btrim(regexp_replace(split_part(coalesce(p_text, ''), E'\n', 1), '\s+', ' ', 'g')) t) x
$$;

-- the dev slide's bug facts for the week starting p_week: {fixed, open, lines, reporters}
create function app.townhall_bug_facts(p_week date) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  with w as (select p_week::timestamp at time zone 'America/Toronto' a, (p_week + 7)::timestamp at time zone 'America/Toronto' z),
  f as (
    select b.number, b.reporter_id, b.status_changed_at,
           coalesce(nullif(btrim(u.greeting_name), ''), nullif(btrim(u.full_name), ''), 'a teammate') who,
           app.th_short(b.happened, 110) wrong,
           coalesce(nullif(app.th_short(b.admin_notes, 140), ''), case when b.fixed_in is not null then 'fixed in ' || b.fixed_in else 'fixed' end) done
      from bug_reports b join users u on u.id = b.reporter_id, w
     where b.status = 'fixed' and b.status_changed_at >= w.a and b.status_changed_at < w.z),
  n as (select f.*, row_number() over (order by status_changed_at, number) rn from f)
  select jsonb_build_object(
    'fixed', (select count(*) from f),
    'open', (select count(*) from bug_reports where status in ('new', 'triaged')),
    'lines', (select coalesce(jsonb_agg(wrong || ' Fixed: ' || done || ' Thanks, ' || who || '.' order by rn) filter (where rn <= 8), '[]'::jsonb) ||
                     case when count(*) > 8 then jsonb_build_array('and ' || (count(*) - 8) || ' more') else '[]'::jsonb end from n),
    'reporters', (select coalesce(jsonb_agg(jsonb_build_object('user_id', reporter_id, 'name', who, 'fixed', c) order by who), '[]'::jsonb)
                    from (select reporter_id, who, count(*) c from f group by reporter_id, who) r))
$$;

create function app.townhall_slides_4620(p_week date) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  v_old jsonb := app.townhall_slides_pre4620(p_week);
  v_b jsonb := app.townhall_bug_facts(p_week);
  v_out jsonb := '[]'::jsonb;
  s jsonb;
begin
  for s in select x from jsonb_array_elements(v_old) with ordinality t(x, o) order by o loop
    if s ->> 'key' = 'dev' then
      s := s || jsonb_build_object(
        'points', coalesce(s -> 'points', '[]'::jsonb) || jsonb_build_array(app.th_point('Bugs fixed this week', v_b ->> 'fixed'), app.th_point('Bugs still open', v_b ->> 'open')),
        'bug_lines', v_b -> 'lines', 'reporters', v_b -> 'reporters');
    end if;
    v_out := v_out || jsonb_build_array(s);
  end loop;
  return v_out;
end $$;

alter function app.townhall_slides(date) rename to townhall_slides_pre4620;
create function app.townhall_slides(p_week date) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$ select app.townhall_slides_4620(p_week) $$;
select pg_temp.copy_grants('app.townhall_slides(date)'::regprocedure, 'app.townhall_slides_pre4620(date)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['th_short', 'townhall_bug_facts', 'townhall_slides_4620', 'townhall_slides_pre4620', 'townhall_slides']) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
