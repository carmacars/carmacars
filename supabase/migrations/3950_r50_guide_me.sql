-- 3950 (Guide me; docs/changes/2026-11-24-r50-guide-me.md): an optional coach in every staff portal that walks a person
-- through a real workflow while they do it (web/src/features/guide-me). This migration keeps what it needs server side:
--   guide_me_prefs   one row a person: keep Guide me on (off by default);
--   guide_me_runs    one row a run of a workflow: who, which workflow, the portal, the steps, the step reached, the
--                    steps skipped and how it ended (active, completed, exited). Starts, completions and the drop-off step
--                    are counted from it; no personal data beyond the user id, no page content.
-- Functions (security definer, search_path public, app, pg_temp; the server role alone executes them, through the
-- signed-in person's /api/guide-me route):
--   public.guide_me_state(p_by)        the preference and the run to resume (active, last 7 days)
--   public.guide_me_do(p_by, p)        op pref | start | step | end, for staff and Admins only, 400 writes a person a day
--   public.guide_me_report(p_by)       Admins: completion per staff member and the drop-off step per workflow (30 days)
-- Both tables: row-level security with admin_all (and each person reads their own), the audit trigger. SCHEMA_MARKER 3951.
-- No applied migration is edited.

create table if not exists guide_me_prefs (
  user_id     uuid primary key references users (id) on delete cascade,
  keep_on     boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
comment on table guide_me_prefs is 'Guide me (3950): a staff member keeps the step-by-step coach on (off by default).';

create table if not exists guide_me_runs (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references users (id) on delete cascade,
  flow         text not null check (flow ~ '^[a-z0-9-]{2,60}$'),
  portal       text not null check (portal in ('admin', 'va', 'field')),
  steps_total  int not null check (steps_total between 1 and 60),
  step_index   int not null default 0 check (step_index >= 0 and step_index <= steps_total),
  step_id      text check (step_id is null or step_id ~ '^[a-z0-9-]{1,60}$'),
  skipped      text[] not null default '{}' check (cardinality(skipped) <= 60),
  status       text not null default 'active' check (status in ('active', 'completed', 'exited')),
  started_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  finished_at  timestamptz,
  check ((status = 'active') = (finished_at is null))
);
create index if not exists guide_me_runs_user_idx on guide_me_runs (user_id, started_at desc);
create index if not exists guide_me_runs_started_idx on guide_me_runs (started_at desc);
comment on table guide_me_runs is 'Guide me (3950): one run of a workflow by a staff member: the step reached, the steps skipped, and whether it was completed or exited (the drop-off step).';

create trigger guide_me_prefs_updated before update on guide_me_prefs for each row execute function app.set_updated_at();
create trigger guide_me_runs_updated before update on guide_me_runs for each row execute function app.set_updated_at();
create trigger audit_guide_me_prefs after insert or update or delete on guide_me_prefs for each row execute function app.audit_row();
create trigger audit_guide_me_runs after insert or update or delete on guide_me_runs for each row execute function app.audit_row();

alter table guide_me_prefs enable row level security;
alter table guide_me_runs enable row level security;
create policy admin_all on guide_me_prefs for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on guide_me_runs for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy own_read on guide_me_prefs for select to authenticated using (user_id = auth.uid());
create policy own_read on guide_me_runs for select to authenticated using (user_id = auth.uid());
revoke all on guide_me_prefs, guide_me_runs from public, anon, authenticated;
grant select on guide_me_prefs, guide_me_runs to authenticated;
grant all on guide_me_prefs, guide_me_runs to service_role;

-- staff: an Admin, an office function or field work
create or replace function app.guide_me_staff(p_by uuid) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select p_by is not null and exists (select 1 from user_roles r where r.user_id = p_by and r.role in ('admin', 'va', 'field'))
$$;

create or replace function public.guide_me_state(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select case when not app.guide_me_staff(p_by) then null else jsonb_build_object(
    'on', coalesce((select keep_on from guide_me_prefs where user_id = p_by), false),
    'run', (select jsonb_build_object('id', r.id, 'flow', r.flow, 'portal', r.portal, 'index', r.step_index, 'step', r.step_id, 'skipped', to_jsonb(r.skipped), 'started_at', r.started_at)
              from guide_me_runs r where r.user_id = p_by and r.status = 'active' and r.updated_at > now() - interval '7 days'
             order by r.updated_at desc limit 1)) end
$$;

create or replace function public.guide_me_do(p_by uuid, p jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public, app, pg_temp as $$
declare
  v_op text := coalesce(p ->> 'op', '');
  v_run guide_me_runs;
  v_index int := nullif(p ->> 'index', '')::int;
  v_step text := nullif(left(coalesce(p ->> 'step', ''), 60), '');
  v_skipped text[] := coalesce((select array_agg(left(x, 60)) from jsonb_array_elements_text(case when jsonb_typeof(p -> 'skipped') = 'array' then p -> 'skipped' else '[]'::jsonb end) x), '{}');
begin
  if not app.guide_me_staff(p_by) then raise exception 'Guide me is for staff' using errcode = '42501'; end if;
  if v_op not in ('pref', 'start', 'step', 'end') then raise exception 'Unknown Guide me operation' using errcode = '22023'; end if;
  if v_op = 'end' and coalesce(p ->> 'status', '') not in ('completed', 'exited') then raise exception 'Not a way to end a run' using errcode = '22023'; end if;
  -- a run that loops never floods the tables (the audit log included)
  if (select count(*) from guide_me_runs where user_id = p_by and updated_at > now() - interval '1 day') >= 400 then return jsonb_build_object('ok', false, 'reason', 'limit'); end if;
  if v_op = 'pref' then
    insert into guide_me_prefs (user_id, keep_on) values (p_by, coalesce((p ->> 'on')::boolean, false))
    on conflict (user_id) do update set keep_on = excluded.keep_on where guide_me_prefs.keep_on is distinct from excluded.keep_on;
    return jsonb_build_object('ok', true, 'on', coalesce((p ->> 'on')::boolean, false));
  end if;
  if v_op = 'start' then
    -- one active run a person: a new one ends the one before as exited where it stood
    update guide_me_runs set status = 'exited', finished_at = now() where user_id = p_by and status = 'active';
    insert into guide_me_runs (user_id, flow, portal, steps_total, step_index, step_id)
    values (p_by, p ->> 'flow', p ->> 'portal', (p ->> 'total')::int, 0, v_step) returning * into v_run;
    return jsonb_build_object('ok', true, 'id', v_run.id);
  end if;
  select * into v_run from guide_me_runs where id::text = coalesce(p ->> 'run', '') and user_id = p_by;
  if v_run.id is null then return jsonb_build_object('ok', false, 'reason', 'no_run'); end if;
  if v_run.status <> 'active' then return jsonb_build_object('ok', true, 'id', v_run.id, 'status', v_run.status); end if;
  if v_op = 'step' then
    update guide_me_runs set step_index = least(greatest(coalesce(v_index, step_index), 0), steps_total), step_id = coalesce(v_step, step_id), skipped = v_skipped
     where id = v_run.id;
    return jsonb_build_object('ok', true, 'id', v_run.id);
  end if;
  if v_op = 'end' then
    update guide_me_runs set status = p ->> 'status', finished_at = now(), skipped = v_skipped,
           step_index = case when p ->> 'status' = 'completed' then steps_total else least(greatest(coalesce(v_index, step_index), 0), steps_total) end,
           step_id = coalesce(v_step, step_id)
     where id = v_run.id;
    return jsonb_build_object('ok', true, 'id', v_run.id, 'status', p ->> 'status');
  end if;
  raise exception 'Unknown Guide me operation' using errcode = '22023';
exception when check_violation or not_null_violation or invalid_text_representation then
  raise exception 'Not a Guide me event' using errcode = '22023';
end $$;

-- Admin: the last 30 days, per staff member (started, completed, exited, still open, the last one) and per workflow
-- (started, completed, and the step people stop at most)
create or replace function public.guide_me_report(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object(
    'staff', coalesce((select jsonb_agg(x order by x ->> 'name') from (
      select jsonb_build_object('id', u.id, 'name', coalesce(nullif(btrim(u.full_name), ''), u.email), 'on', coalesce(pf.keep_on, false),
        'started', count(r.id), 'completed', count(r.id) filter (where r.status = 'completed'), 'exited', count(r.id) filter (where r.status = 'exited'),
        'active', count(r.id) filter (where r.status = 'active'), 'last', max(r.started_at),
        'flows', coalesce(jsonb_agg(distinct r.flow) filter (where r.status = 'completed'), '[]'::jsonb)) x
        from users u join guide_me_runs r on r.user_id = u.id and r.started_at > now() - interval '30 days'
        left join guide_me_prefs pf on pf.user_id = u.id
       group by u.id, u.full_name, u.email, pf.keep_on) q), '[]'::jsonb),
    'flows', coalesce((select jsonb_agg(x order by x ->> 'flow') from (
      select jsonb_build_object('flow', r.flow, 'started', count(*), 'completed', count(*) filter (where r.status = 'completed'),
        'drop_off', (select jsonb_build_object('step', d.step_id, 'n', count(*)) from guide_me_runs d
                      where d.flow = r.flow and d.status <> 'completed' and d.started_at > now() - interval '30 days' and d.step_id is not null
                        and (d.status = 'exited' or d.updated_at < now() - interval '1 day')
                      group by d.step_id order by count(*) desc, d.step_id limit 1)) x
        from guide_me_runs r where r.started_at > now() - interval '30 days' group by r.flow) q), '[]'::jsonb));
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname = 'guide_me_staff') or (n.nspname = 'public' and p.proname in ('guide_me_state', 'guide_me_do', 'guide_me_report')) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
