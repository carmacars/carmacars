-- 1064_r35k_live_map_team.sql
-- Release 35, part K (docs/changes/2026-11-08-r35-staff-onboarding.md and -close-ended-trips.md).
--   1. Today > Visitors, the live map (and its TV mode and the Sales staff copy): "On rent now" counts every booking on a
--      trip now: on rent, and confirmed with the trip's period covering now though the pickup was never recorded, insurer
--      billed rentals included (it showed 0 with 16 out). New on the same read: "Working now" (staff clocked in, or on a field
--      shift now, with the role and since when) and the Sales leaderboard of the week (bookings credited, Monday to now).
--   2. The team's WhatsApp groups on the portal home too (not only Welcome and the email), once both the academy and the
--      agreement are done, until the person presses I joined (ops_read staff_team_groups).
-- No applied migration is edited: app.live_map_pre0283 (0242's body, behind 0283's wrapper) is patched; app.live_map wrapped.
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '1064: the text to change was not found in %: %', p_sig, left(p_old, 120); end if;
  execute replace(d, p_old, p_new);
end $$;

select pg_temp.patch_fn('app.live_map_pre0283(uuid, jsonb)'::regprocedure,
  '''on_rent_now'', (select count(*) from bookings b where b.status = ''on_rent'' and b.booking_type <> ''owner''),',
  '''on_rent_now'', (select count(*) from bookings b where b.booking_type <> ''owner'' and not coalesce(b.is_placeholder, false)
                       and (b.status = ''on_rent'' or (b.status = ''confirmed'' and b.pickup_at <= now() and b.return_at > now()))),');

-- who is working now: clocked in (office), clocked in on a field shift, or holding a field shift that covers now
create function app.working_now(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('name', x.name, 'role', x.role, 'since', x.since) order by x.since), '[]'::jsonb) from (
    select distinct on (w.user_id) w.user_id, coalesce(nullif(btrim(u.greeting_name), ''), split_part(btrim(coalesce(u.full_name, '')), ' ', 1)) name, w.role, w.since
      from (select e.user_id, (select case when 'cs' = any (sp.functions) then 'Customer service' when 'fleet' = any (sp.functions) then 'Fleet' else 'Finance' end
                                 from staff_profiles sp where sp.user_id = e.user_id) role, e.started_at since, 1 o
              from staff_clock_entries e where e.ended_at is null and e.voided_at is null
            union all
            select f.staff_id, 'Field', f.started_at, 2 from field_shifts f where f.ended_at is null and f.voided_at is null and f.started_at > p_now - interval '16 hours'
            union all
            select pl.staff_id, 'Field (shift)', s.starts_at, 3 from field_shift_plans pl join field_shift_slots s on s.id = pl.slot_id
             where pl.cancelled_at is null and s.cancelled_at is null and s.starts_at <= p_now and s.ends_at > p_now) w
      join users u on u.id = w.user_id
     order by w.user_id, w.o) x
$$;

-- the Sales leaderboard of the week (bookings credited, Monday 00:00 Toronto to now)
create function app.sales_week_board(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('name', x.name, 'bookings', x.n) order by x.n desc, x.name), '[]'::jsonb) from (
    select coalesce(nullif(btrim(u.greeting_name), ''), split_part(btrim(coalesce(u.full_name, '')), ' ', 1)) name, count(*)::int n
      from bookings b join users u on u.id = b.sales_staff_id
     where b.confirmed_at >= (date_trunc('week', p_now at time zone 'America/Toronto')) at time zone 'America/Toronto' and b.booking_type <> 'owner'
     group by 1 order by 2 desc limit 8) x
$$;

alter function app.live_map(uuid, jsonb) rename to live_map_pre1064;
create function app.live_map(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := app.live_map_pre1064(p_by, p);
begin
  if jsonb_typeof(v) <> 'object' then return v; end if;
  return v || jsonb_build_object('working', app.working_now(now()), 'leaderboard', app.sales_week_board(now()));
end $$;
revoke all on function app.live_map(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.live_map(uuid, jsonb) to service_role;
do $$ begin
  if has_function_privilege('authenticated', 'app.live_map_pre1064(uuid, jsonb)', 'execute') then
    grant execute on function app.live_map(uuid, jsonb) to authenticated;
  end if;
end $$;

-- the groups on the home page: academy and agreement done, a link set, not joined yet
create function app.staff_team_groups(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when app.staff_is_member(p_user) and not app.academy_locked(p_user)
                   and (app.staff_agreement_signed(p_user) or exists (select 1 from staff_profiles sp where sp.user_id = p_user and sp.agreement_waived_at is not null))
                   and not exists (select 1 from staff_profiles sp where sp.user_id = p_user and sp.team_group_joined_at is not null)
              then app.staff_groups(p_user) else '[]'::jsonb end
$$;

-- the inactivity lock (1060) at the door's first step, which every call takes: a locked staff account opens nothing; any
-- other staff call keeps its last use (to the hour)
alter function app.door_begin(uuid, text) rename to door_begin_pre1064;
create function app.door_begin(p_user uuid, p_aal text) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.door_begin_pre1064(p_user, p_aal);
  if p_user is not null then
    if app.inactive_locked(p_user) then
      raise exception 'Your account is locked for inactivity. Ask an Admin to unlock it.' using errcode = '42501';
    end if;
    perform app.staff_touch(p_user);
  end if;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1064;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'ops_read' and p_name = 'staff_team_groups' then
    perform app.door_begin(p_user, p_aal);
    return app.staff_team_groups(p_user);
  end if;
  return app.door_pre1064(p_user, p_aal, p_call, p_name, p);
end $$;
revoke all on function app.door(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function app.door(uuid, text, text, text, jsonb) to service_role;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['working_now', 'sales_week_board', 'live_map_pre1064', 'staff_team_groups', 'door_pre1064', 'door_begin', 'door_begin_pre1064'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- every new table of part K: the Admin's read policy and the audit log (the house rules, suites 03 and 04)
do $$
declare t text;
begin
  foreach t in array array['staff_agreement_auto', 'staff_seen', 'hiring_auto_hires', 'staff_clock_entries', 'staff_clock_reminders', 'townhall_decks', 'trip_close_decisions'] loop
    execute format('drop policy if exists admin_all on %I', t);
    execute format('create policy admin_all on %I for select to authenticated using (app.is_admin())', t);
    if not exists (select 1 from pg_trigger where tgrelid = t::regclass and tgname = 'audit_' || t) then
      execute format('create trigger %I after insert or update or delete on %I for each row execute function app.audit_row()', 'audit_' || t, t);
    end if;
  end loop;
end $$;
update notification_catalogue set emitted_by = 'app.job_staff_agreements (1060)' where code in ('staff_agreement_reminder', 'staff_team_group');
update notification_catalogue set emitted_by = 'app.job_staff_inactivity (1060)' where code = 'staff_inactivity_warning';
