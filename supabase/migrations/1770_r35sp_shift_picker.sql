-- 1770_r35sp_shift_picker.sql
-- Release 35, part SP (docs/changes/2026-11-11-r35-shift-picker.md): the field staff shift picker, completed. Builds on 0880
-- (published slots, the academy gate), 0931 (give up with a reason, late flag, offers, swaps) and 1051 (jobs on shifts).
--   1. Availability: each field person ticks when they can usually work (a weekly grid, morning 6 to 12, afternoon 12 to 5,
--      evening 5 to 11, per ISO weekday, plus a note). A required onboarding step for field staff (Welcome; after the steps
--      before it, the portal opens once it is in); editable later (Profile, My shifts). Field staff already onboarded when
--      this ships are not held: they get a To do instead (staff_profiles.availability_grandfathered). Fleet and Admin see it
--      on each person on the field jobs board, and a "who is free when" count per weekday and part of the day.
--   2. Standing weekly shifts (field_standing_shifts): "every Saturday 10 to 6". Each published slot of that weekday with the
--      same start and end, up to field_standing_ahead_days ahead, is claimed for the person through field_shift_book (so
--      capacity, overlaps and the academy gate still decide), first when the slot is published, and every hour. A single date
--      is dropped with a reason (claimed: the give-up rules of 0931, late flag and offer; not yet claimed: skipped); a slot the
--      person once held and left is never claimed again for them. Ending the standing shift stops new claims (the shifts
--      already claimed stay theirs). Fleet and Admin can add, skip or end one for a person.
--   3. Rules: field_min_shifts_week (2) shifts claimed within the next field_claim_ahead_days (7). Hourly, an eligible field
--      person (academy passed, onboarded, not a test account) under the minimum gets a To do and a push (a text when they have
--      no phone alerts), at most once a day; the To do closes once they reach it. The board shows who is under it.
--   4. Unclaimed slots: a published slot nobody holds field_unclaimed_alert_hours (48) before it starts alerts Fleet and Admin
--      with a To do naming the people to ask: eligible, available then (item 1), free then, under their minimum. The To do
--      closes when someone takes the slot. A slot with an open give-up offer is left to 0931's own alert.
--   5. Publishing: each slot on the board shows how many eligible people are available and free for it, with the suggested
--      people and one-tap Add.
-- No applied migration is edited: staff_onboarding_state, staff_welcome, field_my_shifts, field_board and the door are wrapped.
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

-- ================================================================ settings
alter table program_settings
  add column if not exists field_min_shifts_week integer not null default 2 check (field_min_shifts_week between 0 and 14),
  add column if not exists field_claim_ahead_days integer not null default 7 check (field_claim_ahead_days between 1 and 14),
  add column if not exists field_unclaimed_alert_hours integer not null default 48 check (field_unclaimed_alert_hours between 0 and 336),
  add column if not exists field_standing_ahead_days integer not null default 14 check (field_standing_ahead_days between 1 and 14);
comment on column program_settings.field_min_shifts_week is 'Field shifts (1770): the fewest shifts a field person should hold within the next field_claim_ahead_days; under it they get a To do and a push or text. 0 for off.';
comment on column program_settings.field_claim_ahead_days is 'Field shifts (1770): the days ahead counted for field_min_shifts_week (7: the next week).';
comment on column program_settings.field_unclaimed_alert_hours is 'Field shifts (1770): a published slot nobody holds this many hours before it starts alerts Fleet and Admin with the people to ask. 0 for off.';
comment on column program_settings.field_standing_ahead_days is 'Field shifts (1770): how many days ahead a standing weekly shift claims its matching published slots (at most 14, as publishing).';

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description) values
  ('field_under_minimum', 'fleet', 'Claim your field shifts for the coming week', 'normal', 'none', null, 'A field person holds fewer shifts than the minimum for the coming days. Claim shifts on My shifts (or set a standing weekly shift).'),
  ('field_slot_unclaimed', 'fleet', 'A published field shift has nobody', 'high', 'none', null, 'Nobody claimed a published shift close to its start. Ask the suggested people, or put someone on it on the field jobs board.'),
  ('field_availability', 'fleet', 'Tick when you can usually work', 'normal', 'none', null, 'Profile > When you can work: tick the mornings, afternoons and evenings you can usually work. Fleet plans the shifts from it.')
on conflict (task_type) do nothing;
insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  ('field_under_minimum', 'You hold fewer field shifts than the minimum', 'Field work', '{assigned}', 'normal', 'alerts', true, false, 'A field person under field_min_shifts_week for the next field_claim_ahead_days, at most once a day (1770).', 159),
  ('field_slot_unclaimed', 'A published field shift has nobody', 'Field work', '{admin,on_duty:fleet}', 'urgent', 'alerts', true, false, 'Nobody claimed a published shift field_unclaimed_alert_hours before it starts; the people to ask are named (1770).', 160)
on conflict (rule) do nothing;

-- ================================================================ 1. availability
-- the 21 cells of the grid: ISO weekday (1 Monday .. 7 Sunday) and part of the day
create function app.fx_avail_keys() returns text[]
language sql immutable as $$
  select array_agg(d || ':' || p order by d, o) from generate_series(1, 7) d, unnest(array['am', 'pm', 'eve']) with ordinality x(p, o)
$$;

create table field_availability (
  user_id     uuid primary key references users (id) on delete cascade,
  slots       text[] not null default '{}' check (slots <@ app.fx_avail_keys()),
  note        text check (length(note) <= 300),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  updated_by  uuid references users (id)
);
comment on table field_availability is 'When a field person can usually work (1770): slots are ISO weekday and part of the day (am 6 to 12, pm 12 to 5, eve 5 to 11, Toronto), e.g. 6:am. A required onboarding step for field staff; Fleet and Admin read it on the field jobs board.';
create trigger field_availability_updated before update on field_availability for each row execute function app.set_updated_at();
alter table field_availability enable row level security;
create policy admin_all on field_availability for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy own_select on field_availability for select to authenticated using (user_id = app.uid());
revoke all on field_availability from public, anon, authenticated;
grant select on field_availability to authenticated;
grant all on field_availability to service_role;
create trigger audit_field_availability after insert or update or delete on field_availability for each row execute function app.audit_row();

alter table staff_profiles add column if not exists availability_grandfathered boolean not null default false;
comment on column staff_profiles.availability_grandfathered is 'Field staff already onboarded when availability became an onboarding step (1770): not held by it; a To do asks them instead.';

-- the parts of the day a shift covers: more than an hour of the part, or at least half of a short shift
create function app.fx_parts(p_start timestamptz, p_end timestamptz) returns text[]
language sql stable as $$
  with b as (select p_start at time zone 'America/Toronto' as ls, p_end at time zone 'America/Toronto' as le),
       parts(k, a, z) as (values ('am', interval '6 hours', interval '12 hours'), ('pm', interval '12 hours', interval '17 hours'), ('eve', interval '17 hours', interval '23 hours')),
       cells as (select extract(isodow from (b.ls::date + g))::int || ':' || p.k as cell, least(b.le, (b.ls::date + g) + p.z) - greatest(b.ls, (b.ls::date + g) + p.a) as ov, b.le - b.ls as len
                   from b, generate_series(0, 1) g, parts p)
  select coalesce(array_agg(distinct c.cell order by c.cell), '{}') from cells c where c.ov > interval '0' and (c.ov > interval '1 hour' or c.ov * 2 >= c.len)
$$;

-- a field person in the field function (the gate not applied: onboarding asks it of them)
create function app.fx_field_member(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from user_roles r join users u on u.id = r.user_id
                   join staff_profiles sp on sp.user_id = r.user_id and 'field' = any (sp.functions) and sp.is_active
                  where r.user_id = p_user and r.role = 'field' and u.status = 'active')
$$;

create function app.fx_availability_required(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.fx_field_member(p_user) and not coalesce((select sp.availability_grandfathered from staff_profiles sp where sp.user_id = p_user), false)
$$;

create function app.fx_has_availability(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from field_availability a where a.user_id = p_user and cardinality(a.slots) > 0)
$$;

-- available then by the grid: every part of the day the shift covers is ticked
create function app.fx_available(p_user uuid, p_start timestamptz, p_end timestamptz) returns boolean
language sql stable security definer set search_path = public, app as $$
  select cardinality(app.fx_parts(p_start, p_end)) > 0
     and coalesce((select app.fx_parts(p_start, p_end) <@ a.slots from field_availability a where a.user_id = p_user), false)
$$;

create function app.fx_availability_view(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('slots', coalesce(to_jsonb(a.slots), '[]'::jsonb), 'note', a.note, 'updated_at', a.updated_at,
           'required', app.fx_availability_required(p_user), 'set', coalesce(cardinality(a.slots) > 0, false))
    from (select 1) one left join field_availability a on a.user_id = p_user
$$;

-- p: slots (array of cells), note
create function app.fx_availability_save(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_slots text[];
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
begin
  if not app.fx_field_member(p_user) then raise exception 'Only field staff give their availability' using errcode = '42501'; end if;
  if jsonb_typeof(p -> 'slots') is distinct from 'array' then raise exception 'Tick the times you can usually work' using errcode = '22023'; end if;
  select coalesce(array_agg(distinct x order by x), '{}') into v_slots from jsonb_array_elements_text(p -> 'slots') x;
  if not v_slots <@ app.fx_avail_keys() then raise exception 'That is not a time on the grid' using errcode = '22023'; end if;
  if cardinality(v_slots) = 0 then raise exception 'Tick at least one time you can usually work' using errcode = '22023'; end if;
  if length(v_note) > 300 then raise exception 'The note is at most 300 characters' using errcode = '22023'; end if;
  insert into field_availability (user_id, slots, note, updated_by) values (p_user, v_slots, v_note, p_user)
  on conflict (user_id) do update set slots = excluded.slots, note = excluded.note, updated_by = excluded.updated_by;
  update tasks set status = 'done', completed_at = now(), completed_by = p_user, completion_note = 'Availability given'
   where dedupe_key = 'field_availability:' || p_user and status in ('open', 'in_progress', 'waiting');
  return app.fx_availability_view(p_user) || jsonb_build_object('onboarded', app.staff_fully_onboarded(p_user));
end $$;

-- onboarding: the step, after the ones before it
create trigger field_availability_onboarding after insert or update or delete on field_availability for each row execute function app.staff_onboarding_trg();

alter function app.staff_onboarding_state(uuid) rename to staff_onboarding_state_pre1770;
create function app.staff_onboarding_state(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.staff_onboarding_state_pre1770(p_user);
  v_req boolean;
  v_ok boolean;
begin
  if not coalesce((v ->> 'member')::boolean, false) then return v; end if;
  v_req := app.fx_availability_required(p_user);
  v_ok := not v_req or app.fx_has_availability(p_user);
  return v || jsonb_build_object('availability', v_ok, 'availability_required', v_req,
    'step', case when coalesce(v ->> 'step', 'done') <> 'done' then v ->> 'step' when not v_ok then 'availability' else 'done' end,
    'done', coalesce((v ->> 'done')::boolean, false) and v_ok);
end $$;
select pg_temp.copy_grants('app.staff_onboarding_state(uuid)'::regprocedure, 'app.staff_onboarding_state_pre1770(uuid)'::regprocedure);

-- Welcome: the availability step after the profile, open from the start
alter function app.staff_welcome(uuid) rename to staff_welcome_pre1770;
create function app.staff_welcome(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.staff_welcome_pre1770(p_user);
  v_steps jsonb := '[]'::jsonb;
  v_av jsonb;
  x jsonb;
begin
  if not app.fx_field_member(p_user) then return v; end if;
  v_av := app.fx_availability_view(p_user);
  for x in select y from jsonb_array_elements(coalesce(v -> 'steps', '[]'::jsonb)) y loop
    v_steps := v_steps || x;
    if x ->> 'key' = 'profile' then
      v_steps := v_steps || jsonb_build_object('key', 'availability', 'done', (v_av ->> 'set')::boolean, 'open', true, 'slots', v_av -> 'slots', 'note', v_av -> 'note',
        'required', (v_av ->> 'required')::boolean);
    end if;
  end loop;
  return v || jsonb_build_object('steps', v_steps);
end $$;
select pg_temp.copy_grants('app.staff_welcome(uuid)'::regprocedure, 'app.staff_welcome_pre1770(uuid)'::regprocedure);

-- ================================================================ 2. standing weekly shifts
create table field_standing_shifts (
  id          uuid primary key default gen_random_uuid(),
  staff_id    uuid not null references users (id),
  weekday     smallint not null check (weekday between 1 and 7),
  start_time  time not null,
  end_time    time not null,
  note        text check (length(note) <= 200),
  created_by  uuid not null references users (id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  ended_at    timestamptz,
  ended_by    uuid references users (id),
  check (end_time > start_time and end_time - start_time <= interval '16 hours')
);
comment on table field_standing_shifts is 'A standing weekly field shift (1770): every <weekday> <start> to <end> (Toronto). Each published slot of that weekday with the same hours, up to field_standing_ahead_days ahead, is claimed for the person through field_shift_book (capacity, overlaps and the academy gate still decide). Ended: no new claims.';
create unique index field_standing_one on field_standing_shifts (staff_id, weekday, start_time) where ended_at is null;
create index field_standing_active on field_standing_shifts (weekday) where ended_at is null;
create trigger field_standing_shifts_updated before update on field_standing_shifts for each row execute function app.set_updated_at();

create table field_standing_skips (
  standing_id uuid not null references field_standing_shifts (id),
  day         date not null,
  reason      text check (length(reason) <= 300),
  created_by  uuid not null references users (id),
  created_at  timestamptz not null default now(),
  primary key (standing_id, day)
);
comment on table field_standing_skips is 'A date dropped from a standing weekly shift (1770): never claimed for it. A claimed date was given up with the 0931 rules first.';

alter table field_shift_plans add column if not exists standing_id uuid references field_standing_shifts (id);
comment on column field_shift_plans.standing_id is 'Claimed for the person by their standing weekly shift (1770).';

alter table field_standing_shifts enable row level security;
alter table field_standing_skips enable row level security;
create policy admin_all on field_standing_shifts for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on field_standing_skips for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy own_select on field_standing_shifts for select to authenticated using (staff_id = app.uid());
revoke all on field_standing_shifts, field_standing_skips from public, anon, authenticated;
grant select on field_standing_shifts to authenticated;
grant all on field_standing_shifts, field_standing_skips to service_role;
create trigger audit_field_standing_shifts after insert or update or delete on field_standing_shifts for each row execute function app.audit_row();
create trigger audit_field_standing_skips after insert or update or delete on field_standing_skips for each row execute function app.audit_row();

create function app.fx_weekday_name(p_dow integer) returns text
language sql immutable as $$
  select (array['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'])[p_dow]
$$;

create function app.fx_standing_words(st field_standing_shifts) returns text
language sql stable as $$
  select 'Every ' || app.fx_weekday_name(st.weekday) || ', ' || to_char(st.start_time, 'FMHH12:MI AM') || ' to ' || to_char(st.end_time, 'FMHH12:MI AM')
$$;

-- does a slot match a standing shift: the weekday and the same hours (Toronto), the same day
create function app.fx_standing_matches(st field_standing_shifts, s field_shift_slots) returns boolean
language sql stable as $$
  select extract(isodow from s.starts_at at time zone 'America/Toronto')::int = st.weekday
     and (s.starts_at at time zone 'America/Toronto')::time = st.start_time
     and (s.ends_at at time zone 'America/Toronto')::time = st.end_time
     and (s.ends_at at time zone 'America/Toronto')::date = (s.starts_at at time zone 'America/Toronto')::date
$$;

-- claim the matching slots: one standing shift, one slot, or all. A slot that is full, overlaps, or a person the academy holds:
-- left alone (tried again next time). Never a slot the person held before and left, nor a skipped date.
create function app.fx_standing_fill(p_standing uuid default null, p_slot uuid default null, p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  v jsonb;
  n integer := 0;
  v_ahead integer := (app.settings()).field_standing_ahead_days;
begin
  for r in select st.id as sid, st.staff_id, s.id as slot_id
             from field_standing_shifts st join field_shift_slots s on app.fx_standing_matches(st, s)
            where st.ended_at is null and (p_standing is null or st.id = p_standing) and (p_slot is null or s.id = p_slot)
              and s.cancelled_at is null and s.starts_at > p_now and s.starts_at < p_now + make_interval(days => v_ahead)
              and not exists (select 1 from field_standing_skips k where k.standing_id = st.id and k.day = app.local_date(s.starts_at))
              and not exists (select 1 from field_shift_plans x where x.slot_id = s.id and x.staff_id = st.staff_id)
            order by s.starts_at, st.created_at loop
    begin
      v := app.field_shift_book(r.staff_id, r.slot_id, r.staff_id);
      update field_shift_plans set standing_id = r.sid where id = (v ->> 'id')::uuid;
      n := n + 1;
    exception when check_violation or unique_violation or no_data_found then
      null;
    end;
  end loop;
  return n;
end $$;

create function app.fx_slot_standing_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.fx_standing_fill(null, new.id);
  return null;
end $$;
create trigger field_shift_slots_standing after insert on field_shift_slots for each row execute function app.fx_slot_standing_after();

create function app.fx_standing_view(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', st.id, 'weekday', st.weekday, 'start', to_char(st.start_time, 'HH24:MI'), 'end', to_char(st.end_time, 'HH24:MI'),
           'words', app.fx_standing_words(st), 'note', st.note, 'since', st.created_at,
           'next', (select coalesce(jsonb_agg(jsonb_build_object('day', d.day,
                       'state', case when exists (select 1 from field_standing_skips k where k.standing_id = st.id and k.day = d.day) then 'skipped'
                                     when exists (select 1 from field_shift_plans x where x.staff_id = st.staff_id and x.cancelled_at is null and x.standing_id = st.id and app.local_date(x.starts_at) = d.day) then 'claimed'
                                     when exists (select 1 from field_shift_slots s where s.cancelled_at is null and app.local_date(s.starts_at) = d.day and app.fx_standing_matches(st, s)) then 'waiting'
                                     else 'no_slot' end) order by d.day), '[]'::jsonb)
                      from (select g::date as day from generate_series(app.today(), app.today() + 27, interval '1 day') g
                             where extract(isodow from g)::int = st.weekday and (g::date > app.today() or now() < (app.today() + st.start_time) at time zone 'America/Toronto')
                             order by g limit 4) d))
         order by st.weekday, st.start_time), '[]'::jsonb)
    from field_standing_shifts st where st.staff_id = p_user and st.ended_at is null
$$;

-- p: weekday (1..7), start, end ('HH:MI'), note; Fleet or Admin: staff
create function app.fx_standing_add(p_by uuid, p jsonb, p_fleet boolean default false) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_staff uuid := case when p_fleet then nullif(p ->> 'staff', '')::uuid else p_by end;
  v_dow integer := nullif(p ->> 'weekday', '')::integer;
  v_start time;
  v_end time;
  v_id uuid;
begin
  if p_fleet and not app.user_runs_fleet(p_by) then raise exception 'Only Fleet or an Admin sets a standing shift for someone' using errcode = '42501'; end if;
  if not app.is_field_person(v_staff) then raise exception 'A standing shift is for active field staff' using errcode = '23514'; end if;
  begin
    v_start := nullif(p ->> 'start', '')::time;
    v_end := nullif(p ->> 'end', '')::time;
  exception when others then
    raise exception 'Choose the start and the end' using errcode = '22023';
  end;
  if v_dow is null or v_dow not between 1 and 7 then raise exception 'Choose the day of the week' using errcode = '22023'; end if;
  if v_start is null or v_end is null then raise exception 'Choose the start and the end' using errcode = '22023'; end if;
  if v_end <= v_start then raise exception 'The shift must end after it starts, the same day' using errcode = '23514'; end if;
  if v_end - v_start > interval '16 hours' then raise exception 'A shift is at most 16 hours' using errcode = '23514'; end if;
  if (select count(*) from field_standing_shifts x where x.staff_id = v_staff and x.ended_at is null) >= 7 then
    raise exception 'At most 7 standing shifts: end one first' using errcode = '23514';
  end if;
  if exists (select 1 from field_standing_shifts x where x.staff_id = v_staff and x.ended_at is null and x.weekday = v_dow and x.start_time < v_end and v_start < x.end_time) then
    raise exception 'That overlaps a standing shift you already have that day' using errcode = '23514';
  end if;
  insert into field_standing_shifts (staff_id, weekday, start_time, end_time, note, created_by)
  values (v_staff, v_dow, v_start, v_end, nullif(left(btrim(coalesce(p ->> 'note', '')), 200), ''), p_by) returning id into v_id;
  return jsonb_build_object('id', v_id, 'claimed', app.fx_standing_fill(v_id, null), 'locked', app.academy_locked(v_staff));
end $$;

-- p: id
create function app.fx_standing_end(p_by uuid, p jsonb, p_fleet boolean default false) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare st field_standing_shifts;
begin
  if p_fleet and not app.user_runs_fleet(p_by) then raise exception 'Only Fleet or an Admin ends a standing shift for someone' using errcode = '42501'; end if;
  select * into st from field_standing_shifts where id = nullif(p ->> 'id', '')::uuid and ended_at is null for update;
  if st.id is null then raise exception 'That standing shift is not there any more' using errcode = 'P0002'; end if;
  if not p_fleet and st.staff_id <> p_by then raise exception 'That standing shift is not yours' using errcode = '42501'; end if;
  update field_standing_shifts set ended_at = now(), ended_by = p_by where id = st.id;
  return jsonb_build_object('id', st.id, 'ended', true);
end $$;

-- p: id (the standing shift), day, reason. Claimed that day: given up (0931: reason, late flag, offered to the others; Fleet:
-- taken off). Then the date is skipped, so it is never claimed again for it.
create function app.fx_standing_skip(p_by uuid, p jsonb, p_fleet boolean default false) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  st field_standing_shifts;
  v_day date := nullif(p ->> 'day', '')::date;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  x field_shift_plans;
  v jsonb := '{}'::jsonb;
begin
  if p_fleet and not app.user_runs_fleet(p_by) then raise exception 'Only Fleet or an Admin drops a date for someone' using errcode = '42501'; end if;
  select * into st from field_standing_shifts where id = nullif(p ->> 'id', '')::uuid and ended_at is null;
  if st.id is null then raise exception 'That standing shift is not there any more' using errcode = 'P0002'; end if;
  if not p_fleet and st.staff_id <> p_by then raise exception 'That standing shift is not yours' using errcode = '42501'; end if;
  if v_day is null or extract(isodow from v_day)::int <> st.weekday then raise exception 'Choose one of the dates of this standing shift' using errcode = '22023'; end if;
  if v_day < app.today() or v_day > app.today() + 60 then raise exception 'Choose a date in the next 60 days' using errcode = '22023'; end if;
  if length(coalesce(v_reason, '')) < 3 then raise exception 'Say why you cannot work this shift' using errcode = '22023'; end if;
  if exists (select 1 from field_standing_skips k where k.standing_id = st.id and k.day = v_day) then raise exception 'That date is already dropped' using errcode = '23505'; end if;
  select * into x from field_shift_plans y where y.staff_id = st.staff_id and y.cancelled_at is null and app.local_date(y.starts_at) = v_day
     and (y.standing_id = st.id or ((y.starts_at at time zone 'America/Toronto')::time = st.start_time and (y.ends_at at time zone 'America/Toronto')::time = st.end_time))
   order by (y.standing_id = st.id) desc nulls last limit 1;
  if x.id is not null then
    if p_fleet then
      update field_shift_plans set cancel_reason = left(v_reason, 300) where id = x.id;
      v := app.field_shift_plan_cancel(p_by, jsonb_build_object('id', x.id));
    else
      v := app.fx_shift_cancel(p_by, jsonb_build_object('id', x.id, 'reason', v_reason));
    end if;
  elsif v_day = app.today() and now() >= (v_day + st.start_time) at time zone 'America/Toronto' then
    raise exception 'This shift has started: ask Fleet' using errcode = '23514';
  end if;
  insert into field_standing_skips (standing_id, day, reason, created_by) values (st.id, v_day, left(v_reason, 300), p_by);
  return v || jsonb_build_object('standing', st.id, 'day', v_day, 'was_claimed', x.id is not null);
end $$;

-- ================================================================ 3. the minimum, eligibility and suggestions
-- eligible for shifts: an onboarded active field person (the gate applies), not a test account, not held by the academy
create function app.fx_eligible(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.is_field_person(p_user) and not coalesce((select u.is_test from users u where u.id = p_user), false) and not app.academy_locked(p_user)
$$;

create function app.fx_claimed_ahead(p_user uuid, p_now timestamptz default now()) returns integer
language sql stable security definer set search_path = public, app as $$
  select count(*)::integer from field_shift_plans x
   where x.staff_id = p_user and x.cancelled_at is null and x.ends_at > p_now and x.starts_at < p_now + make_interval(days => (app.settings()).field_claim_ahead_days)
$$;

create function app.fx_under_min(p_user uuid, p_now timestamptz default now()) returns boolean
language sql stable security definer set search_path = public, app as $$
  select (app.settings()).field_min_shifts_week > 0 and app.fx_claimed_ahead(p_user, p_now) < (app.settings()).field_min_shifts_week
$$;

-- the people who could take a slot now: eligible, available then by their grid, free then (on no overlapping shift, this one included)
create function app.fx_slot_free_people(p_slot uuid) returns setof uuid
language sql stable security definer set search_path = public, app as $$
  select u.id from field_shift_slots s, users u
   where s.id = p_slot and app.fx_eligible(u.id) and app.fx_available(u.id, s.starts_at, s.ends_at)
     and not exists (select 1 from field_shift_plans x where x.staff_id = u.id and x.cancelled_at is null and x.starts_at < s.ends_at and s.starts_at < x.ends_at)
$$;

-- the people to ask first: those under their minimum, fewest shifts first
create function app.fx_slot_suggest(p_slot uuid, p_limit integer default 5) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'name', coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email), 'claimed', f.claimed) order by f.claimed, u.full_name), '[]'::jsonb)
    from (select x.id, app.fx_claimed_ahead(x.id) as claimed from app.fx_slot_free_people(p_slot) x(id) where app.fx_under_min(x.id) order by 2 limit p_limit) f
    join users u on u.id = f.id
$$;

-- one field person for the board: availability, standing shifts, shifts held ahead and the minimum
create function app.fx_person_plan(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('availability', (select jsonb_build_object('slots', to_jsonb(a.slots), 'note', a.note, 'updated_at', a.updated_at) from field_availability a where a.user_id = p_user),
    'standing', (select coalesce(jsonb_agg(jsonb_build_object('id', st.id, 'words', app.fx_standing_words(st)) order by st.weekday, st.start_time), '[]'::jsonb)
                   from field_standing_shifts st where st.staff_id = p_user and st.ended_at is null),
    'claimed_ahead', app.fx_claimed_ahead(p_user), 'under_min', app.fx_eligible(p_user) and app.fx_under_min(p_user))
$$;

-- who is free when: per cell of the grid, how many eligible people ticked it
create function app.fx_availability_grid() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('eligible', (select count(*) from users u where app.fx_eligible(u.id)),
    'cells', coalesce((select jsonb_object_agg(k, (select count(*) from field_availability a where k = any (a.slots) and app.fx_eligible(a.user_id))) from unnest(app.fx_avail_keys()) k), '{}'::jsonb))
$$;

-- a slot taken closes its unclaimed To do; a person reaching the minimum has their To do closed
create function app.fx_plan_1770_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  update tasks set status = 'done', completed_at = now(), completion_note = 'Someone took the shift'
   where dedupe_key = 'field_slot_unclaimed:' || new.slot_id and status in ('open', 'in_progress', 'waiting');
  if not app.fx_under_min(new.staff_id) then
    update tasks set status = 'done', completed_at = now(), completion_note = 'The minimum is held'
     where dedupe_key = 'field_under_min:' || new.staff_id and status in ('open', 'in_progress', 'waiting');
  end if;
  return null;
end $$;
create trigger field_shift_plans_1770 after insert on field_shift_plans for each row execute function app.fx_plan_1770_after();

create table field_shift_nags (
  user_id    uuid primary key references users (id) on delete cascade,
  nagged_at  timestamptz not null default now()
);
comment on table field_shift_nags is 'When a field person was last told they hold fewer shifts than the minimum (1770): at most once a day.';
alter table field_shift_nags enable row level security;
create policy admin_all on field_shift_nags for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on field_shift_nags from public, anon, authenticated;
grant all on field_shift_nags to service_role;

alter table field_shift_slots add column if not exists unclaimed_alerted_at timestamptz;
comment on column field_shift_slots.unclaimed_alerted_at is 'Fleet and Admin were alerted that nobody holds this slot field_unclaimed_alert_hours before it starts (1770).';

-- ================================================================ the hourly job: standing claims, unclaimed slots, the minimum
create function app.job_field_shift_plan(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  sl field_shift_slots;
  u record;
  v_claimed integer;
  v_fill integer;
  v_slots integer := 0;
  v_nags integer := 0;
  v_sugg jsonb;
  v_words text;
  v_t uuid;
  v_title text;
begin
  v_fill := app.fx_standing_fill(null, null, p_now);
  -- unclaimed slots
  if s.field_unclaimed_alert_hours > 0 then
    for sl in select * from field_shift_slots x where x.cancelled_at is null and x.unclaimed_alerted_at is null
               and x.starts_at > p_now and x.starts_at <= p_now + make_interval(hours => s.field_unclaimed_alert_hours)
               and not exists (select 1 from field_shift_plans y where y.slot_id = x.id and y.cancelled_at is null)
               and not exists (select 1 from field_shift_offers o where o.slot_id = x.id and o.status = 'open' and o.kind = 'giveaway') loop
      v_sugg := app.fx_slot_suggest(sl.id);
      v_words := app.fx_shift_words(sl.starts_at, sl.ends_at);
      perform app.raise_task(p_type => 'field_slot_unclaimed', p_title => 'Nobody claimed the field shift of ' || v_words,
        p_detail => case when jsonb_array_length(v_sugg) > 0
                         then 'Ask: ' || (select string_agg(x ->> 'name', ', ') from jsonb_array_elements(v_sugg) x) || ' (available then, free, under their minimum). Or put someone on it on the field jobs board.'
                         else 'Nobody under their minimum is available then. Put someone on it on the field jobs board.' end,
        p_related_table => 'field_shift_slots', p_related_id => sl.id, p_queue => 'fleet', p_dedupe => 'field_slot_unclaimed:' || sl.id, p_due_at => sl.starts_at, p_priority => 'high');
      perform app.staff_alert('field_slot_unclaimed', 'field_shift_slot', sl.id, 'unclaimed', 'Nobody claimed the shift of ' || v_words,
        case when jsonb_array_length(v_sugg) > 0 then 'Ask: ' || (select string_agg(x ->> 'name', ', ') from jsonb_array_elements(v_sugg) x) || '.' else 'Put someone on it on the field jobs board.' end,
        jsonb_build_object('path_admin', '/admin/field-jobs', 'path_staff', '/staff/fleet'));
      update field_shift_slots set unclaimed_alerted_at = p_now where id = sl.id;
      v_slots := v_slots + 1;
    end loop;
  end if;
  -- the minimum
  if s.field_min_shifts_week > 0 then
    for u in select x.id, x.phone, coalesce(nullif(btrim(x.greeting_name), ''), x.full_name, x.email) as name from users x where app.fx_eligible(x.id) loop
      v_claimed := app.fx_claimed_ahead(u.id, p_now);
      if v_claimed >= s.field_min_shifts_week then
        update tasks set status = 'done', completed_at = now(), completion_note = 'The minimum is held'
         where dedupe_key = 'field_under_min:' || u.id and status in ('open', 'in_progress', 'waiting');
        continue;
      end if;
      if exists (select 1 from field_shift_nags n where n.user_id = u.id and n.nagged_at > p_now - interval '20 hours') then continue; end if;
      v_title := format('Claim your field shifts (%s): %s of %s for the next %s days', u.name, v_claimed, s.field_min_shifts_week, s.field_claim_ahead_days);
      v_t := app.raise_task(p_type => 'field_under_minimum', p_title => v_title,
        p_detail => format('Hold at least %s shifts in the next %s days: claim them on My shifts, or set a standing weekly shift.', s.field_min_shifts_week, s.field_claim_ahead_days),
        p_related_table => 'users', p_related_id => u.id, p_queue => 'fleet', p_dedupe => 'field_under_min:' || u.id);
      if v_t is not null then update tasks set assigned_to = u.id, title = v_title where id = v_t; end if;
      perform app.staff_alert('field_under_minimum', 'users', u.id, 'day:' || app.local_date(p_now), format('You hold %s of %s field shifts for the next %s days', v_claimed, s.field_min_shifts_week, s.field_claim_ahead_days),
        'Claim shifts on My shifts, or set a standing weekly shift.', jsonb_build_object('assigned_to', u.id, 'path_staff', '/staff/field/shifts'));
      if not exists (select 1 from push_subscriptions ps where ps.user_id = u.id) and app.phone_e164(u.phone) is not null then
        perform app.phone_outbox_put(u.phone, format('CarmaCars: you hold %s of %s field shifts for the next %s days. Claim shifts on My shifts in your staff portal.', v_claimed, s.field_min_shifts_week, s.field_claim_ahead_days),
          'staff', null, null, null, null, 'field_under_min:' || u.id || ':' || app.local_date(p_now), app.sms_quiet_end(p_now), 'queued', null);
      end if;
      insert into field_shift_nags (user_id, nagged_at) values (u.id, p_now) on conflict (user_id) do update set nagged_at = excluded.nagged_at;
      v_nags := v_nags + 1;
    end loop;
  end if;
  return format('%s standing claim(s), %s unclaimed slot(s) alerted, %s person(s) under the minimum told', v_fill, v_slots, v_nags);
end $$;
do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-field-shift-plan', '7 * * * *', 'select app.job_field_shift_plan()');
  end if;
end $$;

-- ================================================================ the field person's My shifts
alter function app.field_my_shifts(uuid) rename to field_my_shifts_pre1770;
create function app.field_my_shifts(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with s as (select app.field_my_shifts_pre1770(p_user) as x)
  select s.x || jsonb_build_object(
    'mine', coalesce((select jsonb_agg(m || jsonb_build_object('standing', x.standing_id is not null, 'weekday', extract(isodow from x.starts_at at time zone 'America/Toronto')::int,
                        'start', to_char(x.starts_at at time zone 'America/Toronto', 'HH24:MI'), 'end', to_char(x.ends_at at time zone 'America/Toronto', 'HH24:MI')))
                      from jsonb_array_elements(s.x -> 'mine') m join field_shift_plans x on x.id = (m ->> 'id')::uuid), '[]'::jsonb),
    'open', coalesce((select jsonb_agg(o || jsonb_build_object('fits', app.fx_available(p_user, (o ->> 'starts_at')::timestamptz, (o ->> 'ends_at')::timestamptz))) from jsonb_array_elements(s.x -> 'open') o), '[]'::jsonb),
    'offers', coalesce((select jsonb_agg(o || jsonb_build_object('fits', app.fx_available(p_user, (o ->> 'starts_at')::timestamptz, (o ->> 'ends_at')::timestamptz))) from jsonb_array_elements(s.x -> 'offers') o), '[]'::jsonb),
    'standing', app.fx_standing_view(p_user),
    'availability', app.fx_availability_view(p_user),
    'rules', jsonb_build_object('min', (app.settings()).field_min_shifts_week, 'ahead', (app.settings()).field_claim_ahead_days, 'claimed', app.fx_claimed_ahead(p_user),
                                'standing_ahead', (app.settings()).field_standing_ahead_days))
    from s
$$;
select pg_temp.copy_grants('app.field_my_shifts(uuid)'::regprocedure, 'app.field_my_shifts_pre1770(uuid)'::regprocedure);

-- ================================================================ the board (Fleet and Admin)
alter function app.field_board(uuid) rename to field_board_pre1770;
create function app.field_board(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with b as (select app.field_board_pre1770(p_user) as x)
  select b.x || jsonb_build_object(
    'staff', coalesce((select jsonb_agg(p || case when coalesce((p ->> 'admin')::boolean, false) then '{}'::jsonb else app.fx_person_plan((p ->> 'id')::uuid) end)
                         from jsonb_array_elements(b.x -> 'staff') p), '[]'::jsonb),
    'slots', coalesce((select jsonb_agg(s || jsonb_build_object('parts', to_jsonb(app.fx_parts((s ->> 'starts_at')::timestamptz, (s ->> 'ends_at')::timestamptz)),
                                         'available', (select count(*) from app.fx_slot_free_people((s ->> 'id')::uuid)),
                                         'suggest', case when jsonb_array_length(s -> 'people') < (s ->> 'capacity')::int then app.fx_slot_suggest((s ->> 'id')::uuid, 3) else '[]'::jsonb end))
                         from jsonb_array_elements(b.x -> 'slots') s), '[]'::jsonb),
    'availability_grid', app.fx_availability_grid(),
    'rules', jsonb_build_object('min', (app.settings()).field_min_shifts_week, 'ahead', (app.settings()).field_claim_ahead_days,
                                'alert_hours', (app.settings()).field_unclaimed_alert_hours, 'standing_ahead', (app.settings()).field_standing_ahead_days))
    from b
$$;
select pg_temp.copy_grants('app.field_board(uuid)'::regprocedure, 'app.field_board_pre1770(uuid)'::regprocedure);

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1770;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  -- availability: an onboarding step, so open while held (the person as they are)
  if p_name in ('my_availability', 'availability_save') and p_call in ('field_read', 'field_do', 'ops_read', 'ops_do', 'va_read', 'va_do') then
    perform app.door_begin(p_user, p_aal);
    if p_user is not null and app.staff_is_member(p_user) then perform set_config('app.onboarding_pass', p_user::text, true); end if;
    if not app.fx_field_member(p_user) then raise exception 'Only field staff give their availability' using errcode = '42501'; end if;
    if p_name = 'my_availability' then return app.fx_availability_view(p_user); end if;
    if p_call not in ('field_do', 'ops_do', 'va_do') then raise exception 'Not permitted' using errcode = '42501'; end if;
    return app.fx_availability_save(p_user, p_);
  end if;
  if p_call = 'field_do' and p_name in ('standing_add', 'standing_end', 'standing_skip') then
    perform app.door_begin(p_user, p_aal);
    if not app.is_field_person(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return case p_name when 'standing_add' then app.fx_standing_add(p_user, p_) when 'standing_end' then app.fx_standing_end(p_user, p_) else app.fx_standing_skip(p_user, p_) end;
  end if;
  if (p_call = 'ops_do' and p_name in ('field_standing_add', 'field_standing_end', 'field_standing_skip')) or (p_call = 'ops_read' and p_name = 'field_slot_suggest') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    if not app.user_runs_fleet(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return case p_name when 'field_standing_add' then app.fx_standing_add(p_user, p_, true) when 'field_standing_end' then app.fx_standing_end(p_user, p_, true)
                       when 'field_standing_skip' then app.fx_standing_skip(p_user, p_, true)
                       else jsonb_build_object('suggest', app.fx_slot_suggest(nullif(p_ ->> 'slot', '')::uuid, 10), 'available', (select count(*) from app.fx_slot_free_people(nullif(p_ ->> 'slot', '')::uuid))) end;
  end if;
  return app.door_pre1770(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre1770(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['fx_avail_keys', 'fx_parts', 'fx_field_member', 'fx_availability_required', 'fx_has_availability', 'fx_available',
              'fx_availability_view', 'fx_availability_save', 'fx_weekday_name', 'fx_standing_words', 'fx_standing_matches', 'fx_standing_fill', 'fx_slot_standing_after',
              'fx_standing_view', 'fx_standing_add', 'fx_standing_end', 'fx_standing_skip', 'fx_eligible', 'fx_claimed_ahead', 'fx_under_min', 'fx_slot_free_people',
              'fx_slot_suggest', 'fx_person_plan', 'fx_availability_grid', 'fx_plan_1770_after', 'job_field_shift_plan', 'door_pre1770', 'field_my_shifts_pre1770',
              'field_board_pre1770', 'staff_onboarding_state_pre1770', 'staff_welcome_pre1770'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ field staff onboarded before this release: a To do, not a hold
update staff_profiles sp set availability_grandfathered = true
 where sp.onboarding_done and sp.is_active and 'field' = any (sp.functions) and app.fx_field_member(sp.user_id);
do $$
declare r record; v_t uuid;
begin
  for r in select sp.user_id, coalesce(nullif(btrim(u.greeting_name), ''), u.full_name, u.email) as name from staff_profiles sp join users u on u.id = sp.user_id
            where sp.availability_grandfathered and not u.is_test and not app.fx_has_availability(sp.user_id) loop
    v_t := app.raise_task(p_type => 'field_availability', p_title => format('Tick when you can usually work (%s)', r.name),
      p_detail => 'Profile > When you can work: the mornings, afternoons and evenings you can usually work. Fleet plans the shifts from it.',
      p_related_table => 'users', p_related_id => r.user_id, p_queue => 'fleet', p_dedupe => 'field_availability:' || r.user_id);
    if v_t is not null then update tasks set assigned_to = r.user_id where id = v_t; end if;
  end loop;
end $$;
-- everyone else in the field function: the step applies now (refresh their kept onboarding flag)
select app.staff_onboarding_refresh(sp.user_id) from staff_profiles sp where 'field' = any (sp.functions) and not sp.availability_grandfathered;
