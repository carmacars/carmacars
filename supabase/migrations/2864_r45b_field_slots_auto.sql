-- 2864 (release 45, part B): field shift slots are published by themselves.
--
-- Field staff could not pick shifts because none were published: slots existed only when Fleet or an Admin published them
-- (field_slot_publish, 0880; the picker of 1770), and the field jobs board warned of handovers and returns on days with no
-- shifts.
--   1. Program settings: field_slots_auto (on), field_slot_template (the shifts: the start and end in Toronto time, how
--      many people, and which days: "every": N days counted from "anchor", and/or "days": weekdays 1 Monday to 7 Sunday;
--      by default the owner's choice: one shift of 10:00 to 17:00 for one person every second day, in the rhythm of the
--      slots already published from Monday November 23, 2026), field_slots_auto_days (14: how far ahead) and
--      field_slots_auto_from (2026-11-23: nothing is published by itself for an earlier day; the owner wants no shifts
--      opened for November 14 to 22).
--   2. Every hour (job_field_shift_plan, before the standing claims): the template's slots are published only forward,
--      after the latest slot already published (by hand or by itself, cancelled or not), up to field_slots_auto_days
--      ahead, and never before field_slots_auto_from. So a day before the latest slot is never filled in, and a slot
--      Fleet or an Admin cancelled is never published again.
--   3. A covering slot: from field_slots_auto_from on, a confirmed booking whose handover, or a confirmed or on-trip
--      booking whose return, falls at a time no slot covers gets a slot of its own (90 minutes before to 90 minutes
--      after, one person), so every job has a shift to claim. Before that day nothing is added. The unclaimed slot alert
--      of 1770 (field_unclaimed_alert_hours, 48) is unchanged and covers these too.
--   4. Published once now, when the migration runs.
-- No applied migration is edited: job_field_shift_plan is wrapped (_pre2864).
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

-- ================================================================ 1. the settings
create function app.field_slot_template_ok(p jsonb) returns boolean
language sql immutable as $$
  select jsonb_typeof(p) = 'array' and jsonb_array_length(p) <= 20 and not exists (
    select 1 from jsonb_array_elements(p) t
     where jsonb_typeof(t) <> 'object' or (t ? 'days' and jsonb_typeof(t -> 'days') <> 'array')
        or (t ? 'every' and (coalesce(t ->> 'every', '') !~ '^[1-9][0-9]?$' or coalesce(t ->> 'anchor', '') !~ '^\d{4}-\d{2}-\d{2}$'))
        or coalesce(t ->> 'start', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' or coalesce(t ->> 'end', '') !~ '^([01][0-9]|2[0-4]):[0-5][0-9]$'
        or coalesce(t ->> 'people', '1') !~ '^[0-9]+$' or coalesce((t ->> 'people')::int, 1) not between 1 and 50
        or exists (select 1 from jsonb_array_elements_text(case when jsonb_typeof(t -> 'days') = 'array' then t -> 'days' else '[]'::jsonb end) d where d !~ '^[1-7]$'))
$$;

alter table program_settings
  add column if not exists field_slots_auto boolean not null default true,
  add column if not exists field_slot_template jsonb not null default
    '[{"every": 2, "anchor": "2026-11-23", "start": "10:00", "end": "17:00", "people": 1}]'::jsonb,
  add column if not exists field_slots_auto_days integer not null default 14 check (field_slots_auto_days between 1 and 14),
  add column if not exists field_slots_auto_from date not null default date '2026-11-23';
alter table program_settings add constraint program_settings_field_slot_template_ok check (app.field_slot_template_ok(field_slot_template));
comment on column program_settings.field_slots_auto is 'Field shifts (2864): the weekly template is published by itself every hour, field_slots_auto_days ahead, and a slot is added for any handover or return no slot covers. Off: Fleet and Admin publish every slot.';
comment on column program_settings.field_slot_template is 'Field shifts (2864): the shifts published by themselves: [{start: "HH:MM", end: "HH:MM", people, every: N days from anchor "YYYY-MM-DD", days: [1..7, Monday is 1]}], Toronto time; every and days are each optional (neither: every day). An end at or before the start runs past midnight. Default: 10:00 to 17:00, one person, every second day from 2026-11-23.';
comment on column program_settings.field_slots_auto_from is 'Field shifts (2864): no slot (template or covering) is published by itself for a day before this one.';
comment on column program_settings.field_slots_auto_days is 'Field shifts (2864): how many days ahead the template is published (1 to 14).';

alter table field_shift_slots add column if not exists auto_source text check (auto_source in ('template', 'cover'));
alter table field_shift_slots add column if not exists cover_booking_id uuid references bookings (id) on delete set null;
alter table field_shift_slots add column if not exists cover_leg text check (cover_leg in ('handover', 'return'));
comment on column field_shift_slots.auto_source is 'Field shifts (2864): published by itself, from the weekly template or to cover a handover or return (cover_booking_id, cover_leg). Null: published by Fleet or an Admin.';
create index if not exists field_shift_slots_auto_idx on field_shift_slots (starts_at, ends_at) where auto_source is not null;

-- ================================================================ 2 and 3. publishing
create function app.field_slots_auto_publish(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  t jsonb;
  d integer;
  v_day date;
  v_s timestamptz;
  v_e timestamptz;
  n_t integer := 0;
  n_c integer := 0;
  r record;
  v_after date;
  v_from date := coalesce(s.field_slots_auto_from, app.local_date(p_now));
begin
  if not coalesce(s.field_slots_auto, false) then return jsonb_build_object('template', 0, 'cover', 0, 'off', true); end if;
  -- only forward: after the latest slot already published (any kind, cancelled too), from field_slots_auto_from on
  v_after := (select max(app.local_date(x.starts_at)) from field_shift_slots x where x.cover_booking_id is null);
  for t in select x from jsonb_array_elements(s.field_slot_template) x loop
    for d in 0 .. s.field_slots_auto_days - 1 loop
      v_day := app.local_date(p_now) + d;
      if v_day < v_from or (v_after is not null and v_day <= v_after) then continue; end if;
      if jsonb_typeof(t -> 'days') = 'array' and not (t -> 'days') @> to_jsonb(extract(isodow from v_day)::int) then continue; end if;
      if t ? 'every' and mod(v_day - (t ->> 'anchor')::date, (t ->> 'every')::int) <> 0 then continue; end if;
      v_s := (v_day + (t ->> 'start')::time) at time zone 'America/Toronto';
      v_e := (v_day + case when t ->> 'end' = '24:00' then interval '24 hours' else (t ->> 'end')::time::interval end) at time zone 'America/Toronto';
      if v_e <= v_s then v_e := v_e + interval '1 day'; end if;
      if v_e <= p_now or v_e - v_s > interval '16 hours' then continue; end if;
      -- once: never again after a cancel, never beside the same hours published by hand
      if exists (select 1 from field_shift_slots x where x.starts_at = v_s and x.ends_at = v_e and (x.auto_source = 'template' or x.cancelled_at is null)) then continue; end if;
      insert into field_shift_slots (starts_at, ends_at, capacity, note, auto_source)
      values (v_s, v_e, coalesce((t ->> 'people')::int, 1), 'Published by itself from the weekly shift template', 'template');
      n_t := n_t + 1;
    end loop;
  end loop;
  -- every handover and return within the window that no slot covers
  for r in select b.id, b.booking_number, x.leg, x.at
             from bookings b cross join lateral (values ('handover', b.pickup_at, b.status = 'confirmed' and b.handed_over_at is null),
                                                        ('return', b.return_at, b.status in ('confirmed', 'on_rent') and b.checked_in_at is null)) x(leg, at, applies)
            where x.applies and x.at > p_now and x.at <= p_now + make_interval(days => s.field_slots_auto_days) and app.local_date(x.at) >= v_from
              and b.booking_type <> 'owner' and not coalesce(b.is_placeholder, false)
              and not exists (select 1 from field_shift_slots z where z.cancelled_at is null and z.starts_at <= x.at and z.ends_at >= x.at)
              and not exists (select 1 from field_shift_slots z where z.cover_booking_id = b.id and z.cover_leg = x.leg and z.starts_at = greatest(x.at - interval '90 minutes', p_now))
  loop
    insert into field_shift_slots (starts_at, ends_at, capacity, note, auto_source, cover_booking_id, cover_leg)
    values (greatest(r.at - interval '90 minutes', p_now), r.at + interval '90 minutes', 1,
            format('Published by itself to cover the %s of %s', case r.leg when 'handover' then 'handover' else 'return' end, r.booking_number), 'cover', r.id, r.leg);
    n_c := n_c + 1;
  end loop;
  return jsonb_build_object('template', n_t, 'cover', n_c);
end $$;
comment on function app.field_slots_auto_publish(timestamptz) is 'r45 (2864): publishes the weekly shift template ahead and a slot for each handover or return no slot covers. Each slot once.';

alter function app.job_field_shift_plan(timestamptz) rename to job_field_shift_plan_pre2864;
create function app.job_field_shift_plan(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare r jsonb;
begin
  begin
    r := app.field_slots_auto_publish(p_now);
  exception when others then
    raise warning 'field slots auto publish: %', sqlerrm;
    r := jsonb_build_object('template', 0, 'cover', 0);
  end;
  return format('%s template slot(s), %s covering slot(s) published; ', r ->> 'template', r ->> 'cover') || app.job_field_shift_plan_pre2864(p_now);
end $$;
select pg_temp.copy_grants('app.job_field_shift_plan(timestamptz)'::regprocedure, 'app.job_field_shift_plan_pre2864(timestamptz)'::regprocedure);
revoke all on function app.job_field_shift_plan_pre2864(timestamptz) from public, anon, authenticated;
grant execute on function app.job_field_shift_plan_pre2864(timestamptz) to service_role;
revoke all on function app.field_slots_auto_publish(timestamptz) from public, anon, authenticated;
grant execute on function app.field_slots_auto_publish(timestamptz) to service_role;

-- ================================================================ 4. now
do $$
declare r jsonb := app.field_slots_auto_publish(now());
begin
  raise notice '2864: % template slot(s) and % covering slot(s) published', r ->> 'template', r ->> 'cover';
end $$;
