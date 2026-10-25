-- 0165_field_pay_class_rules_mode.sql
-- Three gaps from the audit (docs/changes/2026-10-25-field-pay-class-rules-mode.md).
--
-- 1. Field staff pay. CA$18.00 an hour, every two weeks, was only a line in the field staff agreement (0057). Now:
--    field_shifts (clock in and out on the field phone portal, or Fleet and Admin enter hours; every edit after the fact
--    carries a reason and is logged in field_shift_edits), a two-week pay period (Program setting field_pay_anchor, the
--    most recent Sunday before the day this migration ran), a rate per staff member (staff_profiles.hourly_rate_cents,
--    empty: Program setting field_default_hourly_cents, 18.00), an overtime rule that is off (field_overtime_on, weekly
--    hours and multiplier), vacation pay that is off (field_vacation_pay_bps, 0), the pay run (field_pay_runs and
--    field_pay_lines: hours times rate plus the staff member's approved commissions, deductions none), approval, payment
--    recorded by hand (e-Transfer, cash, bank transfer, reference), the pay statement PDF per person (kind pay_statement)
--    and its email (staff_pay_statement). Nothing is paid automatically. Ontario: statutory deductions (income tax, CPP, EI)
--    are not computed; vacation pay is a setting, off.
-- 2. Vehicle class rules: an Admin screen (Settings > Vehicle class rules) to view, add, change, switch off and delete
--    the rules that infer a new car's class, with validation and an audit entry for every change, and a "which class would
--    this car get" test (app.class_rules_read, class_rule_save, class_rule_delete, class_rule_test).
-- 3. A signed car's Management Mode: app.car_mode_change (Admin; an effective date and a reason). Against the owner (a
--    higher fee or share, or a change CarmaCars starts): the owner signs an updated Vehicle Schedule and the date is at
--    least fee_change_notice_days ahead (0135's notice rule). At the owner's request with nothing higher: the change is
--    dated and noticed, and applied on its date by app.job_mode_changes. And an owner is emailed when a change that had
--    not started is cancelled (owner_fee_change_cancelled).
-- Functions changed are wrapped (renamed with the suffix _pre0165). No applied migration is edited.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;
create function pg_temp.service_only(p regprocedure) returns void
language plpgsql as $$
begin
  execute format('revoke all on function %s from public, anon, authenticated', p);
  execute format('grant execute on function %s to service_role', p);
end $$;

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists field_pay_anchor date,
  add column if not exists field_default_hourly_cents integer not null default 1800 check (field_default_hourly_cents between 1 and 20000),
  add column if not exists field_overtime_on boolean not null default false,
  add column if not exists field_overtime_weekly_hours numeric(5, 2) not null default 44 check (field_overtime_weekly_hours between 1 and 100),
  add column if not exists field_overtime_bps integer not null default 15000 check (field_overtime_bps between 10000 and 30000),
  add column if not exists field_vacation_pay_bps integer not null default 0 check (field_vacation_pay_bps between 0 and 2000),
  add column if not exists field_shift_max_hours integer not null default 16 check (field_shift_max_hours between 1 and 24);
-- the anchor: the most recent Sunday before today (every period of two weeks counts from it)
update program_settings
   set field_pay_anchor = app.today() - case when extract(dow from app.today()) = 0 then 7 else extract(dow from app.today())::integer end
 where field_pay_anchor is null;
-- a settings row saved later (a new effective date) keeps that anchor: the column default is the same Sunday
do $$ declare v_a date := app.today() - case when extract(dow from app.today()) = 0 then 7 else extract(dow from app.today())::integer end;
begin
  execute format('alter table program_settings alter column field_pay_anchor set default %L', v_a);
  update program_settings set field_pay_anchor = v_a where field_pay_anchor is null;
end $$;
alter table program_settings alter column field_pay_anchor set not null;
comment on column program_settings.field_pay_anchor is 'Field pay (0165): the first day of a pay period; every period is two weeks counted from it (default: the most recent Sunday before the day 0165 ran). Past pay runs keep their own dates.';
comment on column program_settings.field_default_hourly_cents is 'Field pay (0165): the hourly rate of a field staff member with no rate of their own (CA$18.00).';
comment on column program_settings.field_overtime_on is 'Field pay (0165): off. On, hours past field_overtime_weekly_hours in a week (a week is seven days of the pay period) are paid at field_overtime_bps of the rate.';
comment on column program_settings.field_overtime_weekly_hours is 'Field pay (0165): weekly hours after which overtime applies when the overtime rule is on (Ontario: 44).';
comment on column program_settings.field_overtime_bps is 'Field pay (0165): the overtime multiplier, 15000 is one and a half times.';
comment on column program_settings.field_vacation_pay_bps is 'Field pay (0165): vacation pay added to wages, overtime and commissions on the pay statement; 0 is off (Ontario: 4% is 400). Off by default: the accountant decides.';
comment on column program_settings.field_shift_max_hours is 'Field pay (0165): the longest shift (hours). Clocking out after longer, or entering a longer shift, needs the office to fix it.';
alter table staff_profiles add column if not exists hourly_rate_cents integer check (hourly_rate_cents is null or hourly_rate_cents between 1 and 20000);
comment on column staff_profiles.hourly_rate_cents is 'Field pay (0165): this field staff member''s hourly rate; empty: the Program setting field_default_hourly_cents.';

-- ================================================================ 2. shifts, edits, runs, lines
create table field_shifts (
  id          uuid primary key default gen_random_uuid(),
  staff_id    uuid not null references users (id),
  started_at  timestamptz not null,
  ended_at    timestamptz,
  note        text check (note is null or length(note) <= 300),
  source      text not null default 'clock' check (source in ('clock', 'manual')),
  created_by  uuid references users (id),
  ended_by    uuid references users (id),
  voided_at   timestamptz,
  voided_by   uuid references users (id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (ended_at is null or ended_at > started_at),
  check (voided_at is null or ended_at is not null)
);
comment on table field_shifts is 'Field staff hours (0165): a shift clocked in and out on the field phone portal, or entered by Fleet or an Admin. Whole minutes are paid. An edit after the fact needs a reason and is logged in field_shift_edits; a removed shift is voided, never deleted.';
create unique index field_shifts_one_open on field_shifts (staff_id) where ended_at is null and voided_at is null;
create index field_shifts_staff_idx on field_shifts (staff_id, started_at);
create trigger field_shifts_updated before update on field_shifts for each row execute function app.set_updated_at();

create table field_shift_edits (
  id         uuid primary key default gen_random_uuid(),
  shift_id   uuid not null references field_shifts (id),
  action     text not null check (action in ('add', 'edit', 'void')),
  reason     text,
  before     jsonb,
  after      jsonb,
  edited_by  uuid not null references users (id),
  edited_at  timestamptz not null default now(),
  check (action = 'add' or nullif(btrim(coalesce(reason, '')), '') is not null)
);
comment on table field_shift_edits is 'The log of every shift entered by the office, changed or removed after the fact (0165): who, when, why, before and after.';
create index field_shift_edits_shift_idx on field_shift_edits (shift_id, edited_at);

create sequence if not exists field_pay_statement_seq start 1001;
create table field_pay_runs (
  id           uuid primary key default gen_random_uuid(),
  period_start date not null,
  period_end   date not null,
  status       text not null default 'draft' check (status in ('draft', 'approved', 'paid', 'void')),
  settings     jsonb not null default '{}'::jsonb,
  created_by   uuid references users (id),
  approved_by  uuid references users (id),
  approved_at  timestamptz,
  void_reason  text,
  voided_by    uuid references users (id),
  voided_at    timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check (period_end = period_start + 13),
  check (status <> 'void' or nullif(btrim(coalesce(void_reason, '')), '') is not null)
);
comment on table field_pay_runs is 'A field pay run (0165): one per two-week pay period; draft (recomputed on request), approved (figures and statements frozen, the period''s shifts locked), paid (every line paid), or void (an approved run withdrawn before any payment).';
create unique index field_pay_runs_period_idx on field_pay_runs (period_start) where status <> 'void';
create trigger field_pay_runs_updated before update on field_pay_runs for each row execute function app.set_updated_at();

create table field_pay_lines (
  id                uuid primary key default gen_random_uuid(),
  run_id            uuid not null references field_pay_runs (id),
  staff_id          uuid not null references users (id),
  rate_cents        integer not null,
  minutes_total     integer not null default 0,
  minutes_regular   integer not null default 0,
  minutes_overtime  integer not null default 0,
  overtime_bps      integer not null default 15000,
  wage_cents        bigint not null default 0,
  overtime_cents    bigint not null default 0,
  commission_cents  bigint not null default 0,
  commission_ids    uuid[] not null default '{}',
  vacation_cents    bigint not null default 0,
  gross_cents       bigint not null default 0,
  status            text not null default 'pending' check (status in ('pending', 'paid')),
  statement_number  text unique,
  paid_on           date,
  method            text check (method is null or method in ('e_transfer', 'bank_transfer', 'cash')),
  reference         text,
  note              text,
  paid_by           uuid references users (id),
  paid_at           timestamptz,
  payout_id         uuid references staff_commission_payouts (id),
  emailed_at        timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (run_id, staff_id),
  check ((status = 'paid') = (paid_on is not null and method is not null))
);
comment on table field_pay_lines is 'One person''s pay for a pay run (0165): hours times rate, overtime and vacation pay when those settings are on, plus the staff commissions approved by the period''s end (their ids kept). Deductions: none computed (statutory deductions are the accountant''s).';
create trigger field_pay_lines_updated before update on field_pay_lines for each row execute function app.set_updated_at();

alter table field_shifts enable row level security;
alter table field_shift_edits enable row level security;
alter table field_pay_runs enable row level security;
alter table field_pay_lines enable row level security;
create policy admin_all on field_shifts for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on field_shift_edits for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on field_pay_runs for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on field_pay_lines for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy own_select on field_shifts for select to authenticated using (staff_id = app.uid());
create policy own_select on field_pay_lines for select to authenticated using (staff_id = app.uid()
  and exists (select 1 from field_pay_runs r where r.id = run_id and r.status in ('approved', 'paid')));
revoke all on field_shifts, field_shift_edits, field_pay_runs, field_pay_lines from anon, authenticated;
grant select on field_shifts, field_shift_edits, field_pay_runs, field_pay_lines to authenticated;
grant all on field_shifts, field_shift_edits, field_pay_runs, field_pay_lines to service_role;
create trigger audit_field_shifts after insert or update or delete on field_shifts for each row execute function app.audit_row();
create trigger audit_field_pay_runs after insert or update or delete on field_pay_runs for each row execute function app.audit_row();
create trigger audit_field_pay_lines after insert or update or delete on field_pay_lines for each row execute function app.audit_row();
grant usage on sequence field_pay_statement_seq to service_role;

-- ================================================================ 3. periods and figures
-- The pay period that holds a day: two weeks counted from the anchor.
create or replace function app.fp_period(p_on date) returns table (period_start date, period_end date)
language sql stable security definer set search_path = public, app as $$
  select s, s + 13 from (select a.d + 14 * floor((p_on - a.d)::numeric / 14)::integer as s
                           from (select coalesce((app.settings()).field_pay_anchor, date '2026-10-18') as d) a) x
$$;

create or replace function app.fp_rate(p_staff uuid) returns integer
language sql stable security definer set search_path = public, app as $$
  select coalesce((select sp.hourly_rate_cents from staff_profiles sp where sp.user_id = p_staff), (app.settings()).field_default_hourly_cents)
$$;

-- Is a day in an approved or paid pay run (its shifts cannot change)?
create or replace function app.fp_locked(p_day date) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from field_pay_runs r where r.status in ('approved', 'paid') and p_day between r.period_start and r.period_end)
$$;

-- Shifts keep to their rules whoever writes them: the hours are one person's, never overlapping, never in a locked period.
create or replace function app.field_shift_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_max integer := (app.settings()).field_shift_max_hours;
begin
  if tg_op = 'INSERT' or new.started_at is distinct from old.started_at or new.ended_at is distinct from old.ended_at or new.voided_at is distinct from old.voided_at then
    if new.started_at > now() + interval '1 minute' then raise exception 'A shift cannot start in the future' using errcode = '22023'; end if;
    if new.ended_at is not null and new.ended_at > now() + interval '1 minute' then raise exception 'A shift cannot end in the future' using errcode = '22023'; end if;
    if new.ended_at is not null and new.voided_at is null and new.ended_at - new.started_at > make_interval(hours => v_max) then
      raise exception 'A shift is at most % hours: enter it as two shifts, or ask the office to fix it', v_max using errcode = '22023';
    end if;
    if new.voided_at is null then
      if exists (select 1 from field_shifts o where o.staff_id = new.staff_id and o.id <> new.id and o.voided_at is null
                  and tstzrange(o.started_at, coalesce(o.ended_at, 'infinity'), '[)') && tstzrange(new.started_at, coalesce(new.ended_at, 'infinity'), '[)')) then
        raise exception 'These hours overlap another shift of the same person' using errcode = '23514';
      end if;
    end if;
    if app.fp_locked(app.local_date(new.started_at)) or (tg_op = 'UPDATE' and app.fp_locked(app.local_date(old.started_at)))
       or (new.ended_at is not null and app.fp_locked(app.local_date(new.ended_at))) then
      raise exception 'This day is in a pay run that is approved: the hours cannot change' using errcode = '23514';
    end if;
  end if;
  return new;
end $$;
create trigger field_shifts_guard before insert or update on field_shifts for each row execute function app.field_shift_guard();

-- One person's figures for a period: minutes by day, total, regular and overtime (overtime when the setting is on, by the
-- seven-day weeks of the period; a shift counts on the day it starts), the rate and the amounts.
create or replace function app.fp_figures(p_staff uuid, p_start date, p_end date) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_rate integer := app.fp_rate(p_staff);
  v_w1 integer;
  v_w2 integer;
  v_cap integer := round(s.field_overtime_weekly_hours * 60)::integer;
  v_ot integer := 0;
  v_total integer;
  v_reg integer;
  v_wage bigint;
  v_otc bigint;
begin
  select coalesce(sum(m) filter (where d < p_start + 7), 0), coalesce(sum(m) filter (where d >= p_start + 7), 0)
    into v_w1, v_w2
    from (select app.local_date(x.started_at) as d, round(extract(epoch from (x.ended_at - x.started_at)) / 60)::integer as m
            from field_shifts x where x.staff_id = p_staff and x.voided_at is null and x.ended_at is not null
             and app.local_date(x.started_at) between p_start and p_end) y;
  v_total := v_w1 + v_w2;
  if s.field_overtime_on then v_ot := greatest(v_w1 - v_cap, 0) + greatest(v_w2 - v_cap, 0); end if;
  v_reg := v_total - v_ot;
  v_wage := round(v_reg * v_rate / 60.0);
  v_otc := round(v_ot::bigint * v_rate * s.field_overtime_bps / 600000.0);
  return jsonb_build_object('rate_cents', v_rate, 'minutes_total', v_total, 'minutes_regular', v_reg, 'minutes_overtime', v_ot,
    'overtime_bps', s.field_overtime_bps, 'wage_cents', v_wage, 'overtime_cents', v_otc);
end $$;

-- The commissions a person is owed by the end of a period: approved, not paid, approved before the period ended. Clawbacks
-- are in the sum; a sum of 0 or less is not paid this period (it stays approved and is carried to the next).
create or replace function app.fp_commissions(p_staff uuid, p_end date) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('ids', coalesce(jsonb_agg(c.id order by c.month, c.created_at) filter (where t.total > 0), '[]'::jsonb),
                            'cents', case when coalesce(max(t.total), 0) > 0 then max(t.total) else 0 end,
                            'carried_cents', case when coalesce(max(t.total), 0) > 0 then 0 else coalesce(max(t.total), 0) end)
    from (select coalesce(sum(x.amount_cents), 0) as total from staff_commissions x
           where x.staff_id = p_staff and x.status = 'approved' and x.approved_at < app.local_midnight(p_end + 1)) t
    left join staff_commissions c on c.staff_id = p_staff and c.status = 'approved' and c.approved_at < app.local_midnight(p_end + 1)
$$;

-- A line's amounts from its figures and commissions (vacation pay on wages, overtime and commissions).
create or replace function app.fp_line_values(p_staff uuid, p_start date, p_end date) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  f jsonb := app.fp_figures(p_staff, p_start, p_end);
  c jsonb := app.fp_commissions(p_staff, p_end);
  v_vac bigint;
begin
  v_vac := round(((f ->> 'wage_cents')::bigint + (f ->> 'overtime_cents')::bigint + (c ->> 'cents')::bigint) * (app.settings()).field_vacation_pay_bps / 10000.0);
  return f || jsonb_build_object('commission_cents', (c ->> 'cents')::bigint, 'commission_ids', c -> 'ids', 'commission_carried_cents', (c ->> 'carried_cents')::bigint,
    'vacation_cents', v_vac,
    'gross_cents', (f ->> 'wage_cents')::bigint + (f ->> 'overtime_cents')::bigint + (c ->> 'cents')::bigint + v_vac);
end $$;

create or replace function app.fp_hours_text(p_minutes integer) returns text
language sql immutable as $$ select case when p_minutes % 60 = 0 then (p_minutes / 60) || ' h' when p_minutes < 60 then p_minutes || ' min' else (p_minutes / 60) || ' h ' || (p_minutes % 60) || ' min' end $$;
create or replace function app.fp_period_label(p_start date) returns text
language sql immutable as $$ select to_char(p_start, 'FMMon FMDD') || ' to ' || to_char(p_start + 13, 'FMMon FMDD, YYYY') $$;

-- ================================================================ 4. clock in and out; the office enters and fixes hours
-- Fleet or an Admin enter and fix hours.
create or replace function app.fp_may_edit_hours(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_is_admin(p_user) or app.user_va_has(p_user, 'fleet')
$$;

-- The jobs a person worked between two instants (done in it, or started in it and not finished).
create or replace function app.fp_shift_jobs(p_staff uuid, p_from timestamptz, p_to timestamptz) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', j.id, 'kind', j.kind, 'status', j.status, 'at', coalesce(j.completed_at, j.started_at),
           'vehicle', app.vehicle_name(j.vehicle_id), 'booking_number', (select b.booking_number from bookings b where b.id = j.booking_id))
           order by coalesce(j.completed_at, j.started_at)), '[]'::jsonb)
    from field_jobs j
   where j.assigned_to = p_staff and j.status <> 'cancelled'
     and ((j.completed_at >= p_from and j.completed_at <= p_to) or (j.status <> 'done' and j.started_at >= p_from and j.started_at <= p_to))
$$;

create or replace function app.fp_shift_json(x field_shifts, p_jobs boolean default false) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', x.id, 'staff_id', x.staff_id, 'started_at', x.started_at, 'ended_at', x.ended_at, 'note', x.note, 'source', x.source,
    'minutes', case when x.ended_at is not null then round(extract(epoch from (x.ended_at - x.started_at)) / 60)::integer
                    else floor(extract(epoch from (now() - x.started_at)) / 60)::integer end,
    'open', x.ended_at is null and x.voided_at is null, 'day', app.local_date(x.started_at),
    'locked', app.fp_locked(app.local_date(x.started_at)),
    'edits', (select count(*) from field_shift_edits e where e.shift_id = x.id and e.action <> 'add'),
    'jobs', case when p_jobs then app.fp_shift_jobs(x.staff_id, x.started_at, coalesce(x.ended_at, now())) end)
$$;

create or replace function app.field_clock_in(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x field_shifts;
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
begin
  if not app.user_is_field(p_by) then raise exception 'Only field staff clock in' using errcode = '42501'; end if;
  if length(coalesce(v_note, '')) > 300 then raise exception 'The note is at most 300 characters' using errcode = '22023'; end if;
  select * into x from field_shifts where staff_id = p_by and ended_at is null and voided_at is null;
  if x.id is not null then raise exception 'You are already clocked in since %', app.fmt_time(x.started_at) using errcode = '23514'; end if;
  insert into field_shifts (staff_id, started_at, note, source, created_by) values (p_by, now(), v_note, 'clock', p_by) returning * into x;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'field_clock_in', 'field_shifts', x.id::text, jsonb_build_object('started_at', x.started_at));
  return app.fp_shift_json(x);
end $$;

create or replace function app.field_clock_out(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x field_shifts;
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  v_max integer := (app.settings()).field_shift_max_hours;
begin
  if not app.user_is_field(p_by) then raise exception 'Only field staff clock out' using errcode = '42501'; end if;
  select * into x from field_shifts where staff_id = p_by and ended_at is null and voided_at is null for update;
  if x.id is null then raise exception 'You are not clocked in' using errcode = '23514'; end if;
  if now() - x.started_at > make_interval(hours => v_max) then
    raise exception 'This shift has been open more than % hours. Ask the office to fix it: they set when you finished', v_max using errcode = '23514';
  end if;
  if length(coalesce(v_note, '')) > 300 then raise exception 'The note is at most 300 characters' using errcode = '22023'; end if;
  update field_shifts set ended_at = greatest(now(), started_at + interval '1 second'), ended_by = p_by,
         note = left(case when v_note is null then note when note is null then v_note else note || ' / ' || v_note end, 300)
   where id = x.id returning * into x;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'field_clock_out', 'field_shifts', x.id::text, jsonb_build_object('started_at', x.started_at, 'ended_at', x.ended_at));
  return app.fp_shift_json(x, true);
end $$;

create or replace function app.fp_shift_state(x field_shifts) returns jsonb
language sql immutable as $$ select jsonb_build_object('started_at', x.started_at, 'ended_at', x.ended_at, 'note', x.note) $$;

-- p: {staff, started_at, ended_at, note, reason}
create or replace function app.field_shift_add(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x field_shifts;
  v_staff uuid := nullif(p ->> 'staff', '')::uuid;
  v_from timestamptz := nullif(p ->> 'started_at', '')::timestamptz;
  v_to timestamptz := nullif(p ->> 'ended_at', '')::timestamptz;
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
begin
  if not app.fp_may_edit_hours(p_by) then raise exception 'Only Fleet or an Admin enter hours' using errcode = '42501'; end if;
  if v_staff is null or not exists (select 1 from staff_profiles sp where sp.user_id = v_staff and sp.staff_type = 'field') then
    raise exception 'Choose a field staff member' using errcode = '22023';
  end if;
  if v_from is null or v_to is null then raise exception 'Enter when the shift started and when it ended' using errcode = '22023'; end if;
  if v_to <= v_from then raise exception 'The shift must end after it starts' using errcode = '22023'; end if;
  if length(coalesce(v_note, '')) > 300 then raise exception 'The note is at most 300 characters' using errcode = '22023'; end if;
  insert into field_shifts (staff_id, started_at, ended_at, note, source, created_by, ended_by) values (v_staff, v_from, v_to, v_note, 'manual', p_by, p_by) returning * into x;
  insert into field_shift_edits (shift_id, action, reason, after, edited_by) values (x.id, 'add', nullif(btrim(coalesce(p ->> 'reason', '')), ''), app.fp_shift_state(x), p_by);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'field_shift_add', 'field_shifts', x.id::text, app.fp_shift_state(x) || jsonb_build_object('staff', v_staff));
  return app.fp_shift_json(x);
end $$;

-- p: {id, started_at, ended_at, note, reason}: a reason is always needed
create or replace function app.field_shift_edit(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x field_shifts;
  b jsonb;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_note text := case when p ? 'note' then nullif(btrim(coalesce(p ->> 'note', '')), '') end;
begin
  if not app.fp_may_edit_hours(p_by) then raise exception 'Only Fleet or an Admin change hours' using errcode = '42501'; end if;
  select * into x from field_shifts where id = nullif(p ->> 'id', '')::uuid for update;
  if x.id is null or x.voided_at is not null then raise exception 'Shift not found' using errcode = 'P0002'; end if;
  if v_reason is null or length(v_reason) < 3 then raise exception 'Give the reason: every change to hours is logged with it' using errcode = '22023'; end if;
  if length(coalesce(v_note, '')) > 300 then raise exception 'The note is at most 300 characters' using errcode = '22023'; end if;
  b := app.fp_shift_state(x);
  update field_shifts set started_at = coalesce(nullif(p ->> 'started_at', '')::timestamptz, started_at),
         ended_at = coalesce(nullif(p ->> 'ended_at', '')::timestamptz, ended_at),
         ended_by = case when ended_at is null then p_by else ended_by end,
         note = case when p ? 'note' then v_note else note end
   where id = x.id returning * into x;
  if app.fp_shift_state(x) = b then raise exception 'Nothing changed' using errcode = '22023'; end if;
  insert into field_shift_edits (shift_id, action, reason, before, after, edited_by) values (x.id, 'edit', v_reason, b, app.fp_shift_state(x), p_by);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'field_shift_edit', 'field_shifts', x.id::text, b, app.fp_shift_state(x) || jsonb_build_object('reason', v_reason));
  return app.fp_shift_json(x);
end $$;

-- p: {id, reason}
create or replace function app.field_shift_void(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x field_shifts;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
begin
  if not app.fp_may_edit_hours(p_by) then raise exception 'Only Fleet or an Admin remove hours' using errcode = '42501'; end if;
  select * into x from field_shifts where id = nullif(p ->> 'id', '')::uuid for update;
  if x.id is null or x.voided_at is not null then raise exception 'Shift not found' using errcode = 'P0002'; end if;
  if v_reason is null or length(v_reason) < 3 then raise exception 'Give the reason: every change to hours is logged with it' using errcode = '22023'; end if;
  if x.ended_at is null then update field_shifts set ended_at = greatest(now(), started_at + interval '1 second'), ended_by = p_by where id = x.id; end if;
  if app.fp_locked(app.local_date(x.started_at)) then raise exception 'This day is in a pay run that is approved: the hours cannot change' using errcode = '23514'; end if;
  update field_shifts set voided_at = now(), voided_by = p_by where id = x.id returning * into x;
  insert into field_shift_edits (shift_id, action, reason, before, edited_by) values (x.id, 'void', v_reason, app.fp_shift_state(x), p_by);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'field_shift_void', 'field_shifts', x.id::text, app.fp_shift_state(x), jsonb_build_object('reason', v_reason));
  return jsonb_build_object('voided', true);
end $$;

-- p: {staff, rate_cents (empty: the Program setting), reason}
create or replace function app.field_pay_rate_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_staff uuid := nullif(p ->> 'staff', '')::uuid;
  v_rate integer := nullif(p ->> 'rate_cents', '')::integer;
  v_before integer;
begin
  perform app.assert_admin(p_by);
  if not exists (select 1 from staff_profiles sp where sp.user_id = v_staff and sp.staff_type = 'field') then raise exception 'Choose a field staff member' using errcode = '22023'; end if;
  if v_rate is not null and (v_rate < 1 or v_rate > 20000) then raise exception 'An hourly rate is between $0.01 and $200.00' using errcode = '22023'; end if;
  if nullif(btrim(coalesce(p ->> 'reason', '')), '') is null then raise exception 'Say why the rate changes' using errcode = '22023'; end if;
  select hourly_rate_cents into v_before from staff_profiles where user_id = v_staff;
  update staff_profiles set hourly_rate_cents = v_rate where user_id = v_staff;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'field_pay_rate_set', 'staff_profiles', v_staff::text, jsonb_build_object('hourly_rate_cents', v_before),
          jsonb_build_object('hourly_rate_cents', v_rate, 'reason', btrim(p ->> 'reason')));
  return jsonb_build_object('staff', v_staff, 'rate_cents', app.fp_rate(v_staff), 'is_default', v_rate is null);
end $$;

-- ================================================================ 5. the pay run
-- The lines of a draft run from the shifts and the approved commissions as they stand.
create or replace function app.fp_run_refresh(p_run uuid) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r field_pay_runs;
  u record;
  v jsonb;
  n integer := 0;
begin
  select * into r from field_pay_runs where id = p_run for update;
  if r.status <> 'draft' then raise exception 'Only a draft pay run is recalculated' using errcode = '23514'; end if;
  delete from field_pay_lines where run_id = r.id;
  for u in select sp.user_id as id from staff_profiles sp where sp.staff_type = 'field'
            order by (select coalesce(us.full_name, us.email) from users us where us.id = sp.user_id) loop
    v := app.fp_line_values(u.id, r.period_start, r.period_end);
    continue when (v ->> 'minutes_total')::integer = 0 and (v ->> 'commission_cents')::bigint = 0;
    insert into field_pay_lines (run_id, staff_id, rate_cents, minutes_total, minutes_regular, minutes_overtime, overtime_bps, wage_cents, overtime_cents,
                                 commission_cents, commission_ids, vacation_cents, gross_cents)
    values (r.id, u.id, (v ->> 'rate_cents')::integer, (v ->> 'minutes_total')::integer, (v ->> 'minutes_regular')::integer, (v ->> 'minutes_overtime')::integer,
            (v ->> 'overtime_bps')::integer, (v ->> 'wage_cents')::bigint, (v ->> 'overtime_cents')::bigint, (v ->> 'commission_cents')::bigint,
            array(select (jsonb_array_elements_text(v -> 'commission_ids'))::uuid), (v ->> 'vacation_cents')::bigint, (v ->> 'gross_cents')::bigint);
    n := n + 1;
  end loop;
  update field_pay_runs set updated_at = now() where id = r.id;
  return n;
end $$;

-- p: {date}: the pay period that holds the date (default today). A draft is made, or the period's run is returned.
create or replace function app.field_pay_run_start(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_on date := coalesce(nullif(p ->> 'date', '')::date, app.today());
  per record;
  r field_pay_runs;
begin
  perform app.assert_admin(p_by);
  select * into per from app.fp_period(v_on);
  if per.period_start > app.today() then raise exception 'That pay period has not started' using errcode = '23514'; end if;
  select * into r from field_pay_runs where period_start = per.period_start and status <> 'void';
  if r.id is null then
    insert into field_pay_runs (period_start, period_end, created_by) values (per.period_start, per.period_end, p_by) returning * into r;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'field_pay_run_start', 'field_pay_runs', r.id::text, jsonb_build_object('period_start', r.period_start));
  end if;
  if r.status = 'draft' then perform app.fp_run_refresh(r.id); end if;
  return jsonb_build_object('run_id', r.id, 'status', r.status, 'period_start', r.period_start);
end $$;

create or replace function app.field_pay_run_refresh(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r field_pay_runs := (select x from field_pay_runs x where x.id = nullif(p ->> 'run_id', '')::uuid);
begin
  perform app.assert_admin(p_by);
  if r.id is null then raise exception 'Pay run not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('run_id', r.id, 'lines', app.fp_run_refresh(r.id));
end $$;

create or replace function app.field_pay_run_approve(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r field_pay_runs;
  l field_pay_lines;
  s program_settings := app.settings();
  v_open text;
begin
  perform app.assert_admin(p_by);
  select * into r from field_pay_runs where id = nullif(p ->> 'run_id', '')::uuid for update;
  if r.id is null then raise exception 'Pay run not found' using errcode = 'P0002'; end if;
  if r.status <> 'draft' then raise exception 'This pay run is already %', r.status using errcode = '23514'; end if;
  if r.period_end >= app.today() then
    raise exception 'The pay period ends on %: approve it after that day', app.fmt_day(r.period_end) using errcode = '23514';
  end if;
  select string_agg(coalesce(u.full_name, u.email), ', ') into v_open
    from field_shifts x join users u on u.id = x.staff_id
   where x.ended_at is null and x.voided_at is null and app.local_date(x.started_at) <= r.period_end;
  if v_open is not null then raise exception 'Still clocked in: %. Fix or end their shift first (Hours)', v_open using errcode = '23514'; end if;
  perform app.fp_run_refresh(r.id);
  if not exists (select 1 from field_pay_lines where run_id = r.id) then raise exception 'There are no hours or commissions in this period' using errcode = '23514'; end if;
  for l in select * from field_pay_lines where run_id = r.id order by created_at, id loop
    update field_pay_lines set statement_number = 'PS-' || nextval('field_pay_statement_seq') where id = l.id;
  end loop;
  update field_pay_runs set status = 'approved', approved_by = p_by, approved_at = now(),
         settings = jsonb_build_object('default_rate_cents', s.field_default_hourly_cents, 'overtime_on', s.field_overtime_on, 'overtime_weekly_hours', s.field_overtime_weekly_hours,
                                       'overtime_bps', s.field_overtime_bps, 'vacation_pay_bps', s.field_vacation_pay_bps)
   where id = r.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'field_pay_run_approve', 'field_pay_runs', r.id::text,
          jsonb_build_object('period_start', r.period_start, 'lines', (select count(*) from field_pay_lines where run_id = r.id),
                             'gross_cents', (select sum(gross_cents) from field_pay_lines where run_id = r.id)));
  return jsonb_build_object('run_id', r.id, 'status', 'approved');
end $$;

-- p: {run_id, reason}: an approved run with nothing paid is withdrawn, the shifts unlock
create or replace function app.field_pay_run_void(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r field_pay_runs;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
begin
  perform app.assert_admin(p_by);
  select * into r from field_pay_runs where id = nullif(p ->> 'run_id', '')::uuid for update;
  if r.id is null then raise exception 'Pay run not found' using errcode = 'P0002'; end if;
  if r.status not in ('draft', 'approved') then raise exception 'A pay run with a payment recorded cannot be withdrawn' using errcode = '23514'; end if;
  if exists (select 1 from field_pay_lines where run_id = r.id and status = 'paid') then raise exception 'A pay run with a payment recorded cannot be withdrawn' using errcode = '23514'; end if;
  if v_reason is null then raise exception 'Give the reason' using errcode = '22023'; end if;
  update field_pay_runs set status = 'void', void_reason = v_reason, voided_by = p_by, voided_at = now() where id = r.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'field_pay_run_void', 'field_pay_runs', r.id::text, jsonb_build_object('reason', v_reason, 'period_start', r.period_start));
  return jsonb_build_object('run_id', r.id, 'status', 'void');
end $$;

-- p: {line_id, method, reference, paid_on, note}: the payment made by hand is recorded; the staff commissions of the line are
-- paid with it (one pay_statement payout, 0058); the staff member is emailed their pay statement.
create or replace function app.field_pay_line_paid(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  l field_pay_lines;
  r field_pay_runs;
  v_method text := coalesce(nullif(p ->> 'method', ''), 'e_transfer');
  v_ref text := nullif(btrim(coalesce(p ->> 'reference', '')), '');
  v_on date := coalesce(nullif(p ->> 'paid_on', '')::date, app.today());
  v_payout uuid;
  v_n integer;
  v_sum bigint;
begin
  perform app.assert_admin(p_by);
  select * into l from field_pay_lines where id = nullif(p ->> 'line_id', '')::uuid for update;
  if l.id is null then raise exception 'Pay line not found' using errcode = 'P0002'; end if;
  select * into r from field_pay_runs where id = l.run_id for update;
  if r.status not in ('approved', 'paid') then raise exception 'Approve the pay run before recording a payment' using errcode = '23514'; end if;
  if l.status = 'paid' then raise exception 'This payment is already recorded' using errcode = '23514'; end if;
  if v_method not in ('e_transfer', 'bank_transfer', 'cash') then raise exception 'Choose how it was paid: e-Transfer, bank transfer or cash' using errcode = '22023'; end if;
  if v_method <> 'cash' and (v_ref is null or length(v_ref) < 3) then raise exception 'Enter the reference of the payment' using errcode = '22023'; end if;
  if v_on > app.today() then raise exception 'The date paid cannot be in the future' using errcode = '22023'; end if;
  if l.gross_cents <= 0 then raise exception 'There is nothing to pay on this line' using errcode = '23514'; end if;
  if l.commission_cents > 0 then
    select count(*), coalesce(sum(c.amount_cents), 0) into v_n, v_sum from staff_commissions c
     where c.id = any (l.commission_ids) and c.staff_id = l.staff_id and c.status = 'approved';
    if v_n <> cardinality(l.commission_ids) or v_sum <> l.commission_cents then
      raise exception 'A commission in this line changed after the run was approved. Withdraw the pay run and approve it again' using errcode = '23514';
    end if;
    insert into staff_commission_payouts (staff_id, method, reference, paid_on, pay_period, amount_cents, note, recorded_by)
    values (l.staff_id, 'pay_statement', l.statement_number, v_on, app.month_start(r.period_end), l.commission_cents,
            'Field pay run ' || app.fp_period_label(r.period_start), p_by)
    returning id into v_payout;
    update staff_commissions set status = 'paid', payout_id = v_payout, paid_at = now(), updated_at = now() where id = any (l.commission_ids);
  end if;
  update field_pay_lines set status = 'paid', paid_on = v_on, method = v_method, reference = v_ref, note = nullif(btrim(coalesce(p ->> 'note', '')), ''),
         paid_by = p_by, paid_at = now(), payout_id = v_payout, emailed_at = now()
   where id = l.id;
  if not exists (select 1 from field_pay_lines where run_id = r.id and status = 'pending') then update field_pay_runs set status = 'paid' where id = r.id; end if;
  perform app.emit_event('staff_pay_statement', 'field_pay_line', l.id, jsonb_build_object('staff_id', l.staff_id, 'line_id', l.id), 'staff_pay_statement:' || l.id || ':paid');
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'field_pay_line_paid', 'field_pay_lines', l.id::text,
          jsonb_build_object('staff', l.staff_id, 'gross_cents', l.gross_cents, 'method', v_method, 'reference', v_ref, 'paid_on', v_on, 'payout_id', v_payout));
  return jsonb_build_object('line_id', l.id, 'status', 'paid', 'payout_id', v_payout);
end $$;

-- p: {line_id}: the pay statement email again
create or replace function app.field_pay_line_email(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  l field_pay_lines := (select x from field_pay_lines x where x.id = nullif(p ->> 'line_id', '')::uuid);
begin
  perform app.assert_admin(p_by);
  if l.id is null then raise exception 'Pay line not found' using errcode = 'P0002'; end if;
  if not exists (select 1 from field_pay_runs r where r.id = l.run_id and r.status in ('approved', 'paid')) then raise exception 'Approve the pay run first' using errcode = '23514'; end if;
  perform app.emit_event('staff_pay_statement', 'field_pay_line', l.id, jsonb_build_object('staff_id', l.staff_id, 'line_id', l.id),
    'staff_pay_statement:' || l.id || ':' || floor(extract(epoch from clock_timestamp()))::text);
  update field_pay_lines set emailed_at = now() where id = l.id;
  return jsonb_build_object('line_id', l.id, 'emailed', true);
end $$;

-- ================================================================ 6. reads
create or replace function app.fp_line_json(l field_pay_lines, r field_pay_runs) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', l.id, 'run_id', l.run_id, 'staff_id', l.staff_id, 'name', (select coalesce(u.full_name, u.email) from users u where u.id = l.staff_id),
    'rate_cents', l.rate_cents, 'minutes_total', l.minutes_total, 'minutes_regular', l.minutes_regular, 'minutes_overtime', l.minutes_overtime, 'hours', app.fp_hours_text(l.minutes_total),
    'wage_cents', l.wage_cents, 'overtime_cents', l.overtime_cents, 'commission_cents', l.commission_cents, 'vacation_cents', l.vacation_cents, 'gross_cents', l.gross_cents,
    'status', l.status, 'statement_number', l.statement_number, 'paid_on', l.paid_on, 'method', l.method, 'reference', l.reference, 'emailed_at', l.emailed_at,
    'period_start', r.period_start, 'period_label', app.fp_period_label(r.period_start), 'run_status', r.status)
$$;

-- Admin: the pay run page for the period holding p.date (default today); Fleet: the hours only.
create or replace function app.field_pay_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_admin boolean := app.user_is_admin(p_by);
  v_on date := coalesce(nullif(p ->> 'date', '')::date, app.today());
  per record;
  r field_pay_runs;
  s program_settings := app.settings();
  v_lines jsonb;
begin
  if not app.fp_may_edit_hours(p_by) then raise exception 'Only Fleet or an Admin see field hours and pay' using errcode = '42501'; end if;
  select * into per from app.fp_period(v_on);
  select * into r from field_pay_runs where period_start = per.period_start and status <> 'void';
  if v_admin then
    if r.id is not null then
      select coalesce(jsonb_agg(app.fp_line_json(l, r) order by (select coalesce(u.full_name, u.email) from users u where u.id = l.staff_id)), '[]'::jsonb) into v_lines from field_pay_lines l where l.run_id = r.id;
    else
      -- no run yet: the figures as they stand now
      select coalesce(jsonb_agg(x.j order by x.n), '[]'::jsonb) into v_lines from (
        select coalesce(u.full_name, u.email) as n, jsonb_build_object('staff_id', sp.user_id, 'name', coalesce(u.full_name, u.email),
                 'rate_cents', (v ->> 'rate_cents')::integer, 'minutes_total', (v ->> 'minutes_total')::integer, 'minutes_regular', (v ->> 'minutes_regular')::integer,
                 'minutes_overtime', (v ->> 'minutes_overtime')::integer, 'hours', app.fp_hours_text((v ->> 'minutes_total')::integer), 'wage_cents', (v ->> 'wage_cents')::bigint,
                 'overtime_cents', (v ->> 'overtime_cents')::bigint, 'commission_cents', (v ->> 'commission_cents')::bigint, 'vacation_cents', (v ->> 'vacation_cents')::bigint,
                 'gross_cents', (v ->> 'gross_cents')::bigint, 'status', 'preview') as j
          from staff_profiles sp join users u on u.id = sp.user_id, lateral (select app.fp_line_values(sp.user_id, per.period_start, per.period_end) as v) q
         where sp.staff_type = 'field' and ((q.v ->> 'minutes_total')::integer > 0 or (q.v ->> 'commission_cents')::bigint > 0)) x;
    end if;
  end if;
  return jsonb_build_object('today', app.today(), 'admin', v_admin,
    'period', jsonb_build_object('start', per.period_start, 'end', per.period_end, 'label', app.fp_period_label(per.period_start),
                                 'ended', per.period_end < app.today(), 'prev', per.period_start - 14, 'next', case when per.period_start + 14 <= app.today() then per.period_start + 14 end),
    'settings', jsonb_build_object('anchor', s.field_pay_anchor, 'default_rate_cents', s.field_default_hourly_cents, 'overtime_on', s.field_overtime_on,
                                   'overtime_weekly_hours', s.field_overtime_weekly_hours, 'overtime_bps', s.field_overtime_bps, 'vacation_pay_bps', s.field_vacation_pay_bps,
                                   'shift_max_hours', s.field_shift_max_hours),
    'run', case when v_admin and r.id is not null then jsonb_build_object('id', r.id, 'status', r.status, 'approved_at', r.approved_at,
              'approved_by', (select coalesce(u.full_name, u.email) from users u where u.id = r.approved_by)) end,
    'lines', case when v_admin then v_lines end,
    'totals', case when v_admin then jsonb_build_object('gross_cents', (select coalesce(sum((x ->> 'gross_cents')::bigint), 0) from jsonb_array_elements(v_lines) x),
                                                        'minutes', (select coalesce(sum((x ->> 'minutes_total')::integer), 0) from jsonb_array_elements(v_lines) x)) end,
    'periods', case when v_admin then (select coalesce(jsonb_agg(jsonb_build_object('start', y.s, 'label', app.fp_period_label(y.s), 'run_status', y.st,
                    'gross_cents', y.g) order by y.s desc), '[]'::jsonb)
                  from (select g.s, (select z.status from field_pay_runs z where z.period_start = g.s and z.status <> 'void') as st,
                               (select sum(l.gross_cents) from field_pay_lines l join field_pay_runs z on z.id = l.run_id where z.period_start = g.s and z.status <> 'void') as g
                          from (select per.period_start - 14 * k as s from generate_series(0, 7) k) g) y) end,
    'shifts', coalesce((select jsonb_agg(app.fp_shift_json(x) || jsonb_build_object('name', (select coalesce(u.full_name, u.email) from users u where u.id = x.staff_id))
                          order by x.started_at desc)
                          from field_shifts x where x.voided_at is null and app.local_date(x.started_at) between per.period_start and per.period_end), '[]'::jsonb),
    'clocked_in', coalesce((select jsonb_agg(jsonb_build_object('staff_id', x.staff_id, 'name', (select coalesce(u.full_name, u.email) from users u where u.id = x.staff_id),
                          'started_at', x.started_at, 'shift_id', x.id) order by x.started_at)
                          from field_shifts x where x.ended_at is null and x.voided_at is null), '[]'::jsonb),
    'staff', (select coalesce(jsonb_agg(jsonb_build_object('id', sp.user_id, 'name', coalesce(u.full_name, u.email), 'active', sp.is_active and u.status = 'active',
                          'rate_cents', case when v_admin then app.fp_rate(sp.user_id) end, 'own_rate', case when v_admin then sp.hourly_rate_cents end,
                          'minutes', (select coalesce(sum(round(extract(epoch from (x.ended_at - x.started_at)) / 60)), 0)::integer from field_shifts x
                                       where x.staff_id = sp.user_id and x.voided_at is null and x.ended_at is not null and app.local_date(x.started_at) between per.period_start and per.period_end))
                          order by coalesce(u.full_name, u.email)), '[]'::jsonb)
                from staff_profiles sp join users u on u.id = sp.user_id where sp.staff_type = 'field'));
end $$;

-- A field staff member: their open shift, recent shifts with the jobs done in them, this period so far, their pay statements.
create or replace function app.field_hours_read(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  per record;
  x field_shifts;
  v jsonb;
begin
  if not app.user_is_field(p_by) then raise exception 'Only field staff have hours' using errcode = '42501'; end if;
  select * into per from app.fp_period(app.today());
  select * into x from field_shifts where staff_id = p_by and ended_at is null and voided_at is null;
  v := app.fp_line_values(p_by, per.period_start, per.period_end);
  return jsonb_build_object('today', app.today(), 'now', now(),
    'open', case when x.id is not null then app.fp_shift_json(x, true) end,
    'period', jsonb_build_object('start', per.period_start, 'end', per.period_end, 'label', app.fp_period_label(per.period_start), 'pay_day_note', 'Paid every two weeks'),
    'so_far', jsonb_build_object('hours', app.fp_hours_text((v ->> 'minutes_total')::integer), 'minutes', (v ->> 'minutes_total')::integer, 'rate_cents', (v ->> 'rate_cents')::integer,
                                 'wage_cents', (v ->> 'wage_cents')::bigint, 'overtime_cents', (v ->> 'overtime_cents')::bigint, 'commission_cents', (v ->> 'commission_cents')::bigint,
                                 'vacation_cents', (v ->> 'vacation_cents')::bigint, 'gross_cents', (v ->> 'gross_cents')::bigint),
    'recent', coalesce((select jsonb_agg(app.fp_shift_json(y, true) order by y.started_at desc)
                          from (select * from field_shifts z where z.staff_id = p_by and z.voided_at is null and z.started_at > now() - interval '21 days'
                                 order by z.started_at desc limit 40) y), '[]'::jsonb),
    'statements', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'period_label', app.fp_period_label(r.period_start), 'period_start', r.period_start,
                          'statement_number', l.statement_number, 'hours', app.fp_hours_text(l.minutes_total), 'gross_cents', l.gross_cents, 'status', l.status,
                          'paid_on', l.paid_on, 'method', l.method) order by r.period_start desc)
                          from field_pay_lines l join field_pay_runs r on r.id = l.run_id where l.staff_id = p_by and r.status in ('approved', 'paid')), '[]'::jsonb));
end $$;

-- p: {run_id}: the pay run as rows for a spreadsheet (an Admin)
create or replace function app.field_pay_csv(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r field_pay_runs := (select x from field_pay_runs x where x.id = nullif(p ->> 'run_id', '')::uuid);
begin
  perform app.assert_admin(p_by);
  if r.id is null then raise exception 'Pay run not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('period_start', r.period_start, 'period_end', r.period_end, 'status', r.status,
    'rows', coalesce((select jsonb_agg(jsonb_build_object('statement', l.statement_number, 'name', (select coalesce(u.full_name, u.email) from users u where u.id = l.staff_id),
        'minutes', l.minutes_total, 'overtime_minutes', l.minutes_overtime, 'rate_cents', l.rate_cents, 'wage_cents', l.wage_cents, 'overtime_cents', l.overtime_cents,
        'vacation_cents', l.vacation_cents, 'commission_cents', l.commission_cents, 'gross_cents', l.gross_cents, 'status', l.status, 'paid_on', l.paid_on,
        'method', l.method, 'reference', l.reference)
        order by (select coalesce(u.full_name, u.email) from users u where u.id = l.staff_id)) from field_pay_lines l where l.run_id = r.id), '[]'::jsonb));
end $$;

-- ================================================================ 7. the pay statement (PDF, kind pay_statement; the key is the line)
alter function app.file_access(uuid, text, text) rename to file_access_pre0165;
create or replace function app.file_access(p_user uuid, p_kind text, p_key text) returns boolean
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_kind = 'pay_statement' then
    return p_user is not null and (app.user_is_admin(p_user) or app.user_runs_finance(p_user)
      or exists (select 1 from field_pay_lines l join field_pay_runs r on r.id = l.run_id
                  where l.id = app.file_key_id(p_key) and l.staff_id = p_user and r.status in ('approved', 'paid')));
  end if;
  return app.file_access_pre0165(p_user, p_kind, p_key);
end $$;
select pg_temp.copy_grants('app.file_access(uuid, text, text)'::regprocedure, 'app.file_access_pre0165(uuid, text, text)'::regprocedure);

alter function app.pdf_facts(text, text, uuid) rename to pdf_facts_pre0165;
create or replace function app.pdf_facts(p_kind text, p_key text, p_user uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  l field_pay_lines;
  r field_pay_runs;
  u users;
  sp staff_profiles;
begin
  if p_kind <> 'pay_statement' then return app.pdf_facts_pre0165(p_kind, p_key, p_user); end if;
  select * into l from field_pay_lines where id = app.file_key_id(p_key);
  if l.id is null then return null; end if;
  select * into r from field_pay_runs where id = l.run_id;
  select * into u from users where id = l.staff_id;
  select * into sp from staff_profiles where user_id = l.staff_id;
  return jsonb_build_object('final', r.status in ('approved', 'paid'), 'store', false,
    'title', 'Pay statement', 'file_name', 'carmacars-pay-statement-' || to_char(r.period_start, 'YYYY-MM-DD') || '-' || lower(coalesce(l.statement_number, left(l.id::text, 8))) || '.pdf',
    'issued_at', coalesce(r.approved_at, l.created_at), 'statement_number', l.statement_number,
    'period_start', r.period_start, 'period_end', r.period_end, 'period_label', app.fp_period_label(r.period_start), 'status', l.status, 'run_status', r.status,
    'person', jsonb_build_object('name', coalesce(u.full_name, u.email), 'address', nullif(sp.home_address, '')),
    'rate_cents', l.rate_cents, 'minutes_total', l.minutes_total, 'minutes_regular', l.minutes_regular, 'minutes_overtime', l.minutes_overtime, 'overtime_bps', l.overtime_bps,
    'wage_cents', l.wage_cents, 'overtime_cents', l.overtime_cents, 'vacation_cents', l.vacation_cents, 'commission_cents', l.commission_cents, 'gross_cents', l.gross_cents,
    'vacation_pay_bps', coalesce((r.settings ->> 'vacation_pay_bps')::integer, 0),
    'shifts', coalesce((select jsonb_agg(jsonb_build_object('day', app.local_date(x.started_at), 'from', x.started_at, 'to', x.ended_at,
                  'minutes', round(extract(epoch from (x.ended_at - x.started_at)) / 60)::integer, 'note', x.note) order by x.started_at)
                  from field_shifts x where x.staff_id = l.staff_id and x.voided_at is null and x.ended_at is not null
                   and app.local_date(x.started_at) between r.period_start and r.period_end), '[]'::jsonb),
    'commissions', coalesce((select jsonb_agg(jsonb_build_object('booking', b.booking_number, 'month', c.month, 'kind', c.kind, 'amount_cents', c.amount_cents) order by c.month, b.booking_number)
                  from staff_commissions c join bookings b on b.id = c.booking_id where c.id = any (l.commission_ids)), '[]'::jsonb),
    'paid_on', l.paid_on, 'method', l.method, 'reference', l.reference,
    'company', app.doc_company());
end $$;
select pg_temp.copy_grants('app.pdf_facts(text, text, uuid)'::regprocedure, 'app.pdf_facts_pre0165(text, text, uuid)'::regprocedure);

-- ================================================================ 8. vehicle class rules (Admin: Settings > Vehicle class rules)
create or replace function app.class_rule_json(x vehicle_class_rules) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', x.id, 'rank', x.rank, 'make_key', x.make_key, 'model_re', x.model_re, 'trim_re', x.trim_re, 'body_re', x.body_re,
    'class', x.class, 'class_label', app.class_label(x.class::text), 'aged_years', x.aged_years, 'aged_class', x.aged_class,
    'aged_class_label', case when x.aged_class is not null then app.class_label(x.aged_class::text) end, 'note', x.note, 'is_active', x.is_active,
    'created_at', x.created_at, 'updated_at', x.updated_at)
$$;

create or replace function app.class_rules_read(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object(
    'rules', coalesce((select jsonb_agg(app.class_rule_json(x) order by x.rank, x.make_key nulls last, x.created_at) from vehicle_class_rules x), '[]'::jsonb),
    'classes', coalesce((select jsonb_agg(jsonb_build_object('code', e.v, 'label', app.class_label(e.v)) order by e.o)
                           from (select v::text, row_number() over () as o from unnest(enum_range(null::vehicle_class)) v) e), '[]'::jsonb));
end $$;

-- A pattern must compile (the same engine matches it against a car).
create or replace function app.class_rule_pattern(p_label text, p text) returns text
language plpgsql stable as $$
declare
  v text := nullif(btrim(coalesce(p, '')), '');
begin
  if v is null then return null; end if;
  if length(v) > 300 then raise exception 'The % pattern is at most 300 characters', p_label using errcode = '22023'; end if;
  begin
    perform '' ~* v;
  exception when others then
    raise exception 'The % pattern is not a valid pattern (%)', p_label, sqlerrm using errcode = '22023';
  end;
  return v;
end $$;

-- p: {id (empty: add), rank, make, model_re, trim_re, body_re, class, aged_years, aged_class, note, is_active}
create or replace function app.class_rule_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid := nullif(p ->> 'id', '')::uuid;
  old vehicle_class_rules;
  x vehicle_class_rules;
  v_rank integer;
  v_make text := app.make_key(p ->> 'make');
  v_model text := app.class_rule_pattern('model', p ->> 'model_re');
  v_trim text := app.class_rule_pattern('trim', p ->> 'trim_re');
  v_body text := app.class_rule_pattern('body', p ->> 'body_re');
  v_class vehicle_class;
  v_aged_class vehicle_class;
  v_years smallint;
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
begin
  perform app.assert_admin(p_by);
  if coalesce(p ->> 'rank', '') !~ '^\d{1,3}$' or (p ->> 'rank')::integer < 1 then raise exception 'The rank is a whole number from 1 to 999 (the lowest rank that matches wins)' using errcode = '22023'; end if;
  v_rank := (p ->> 'rank')::integer;
  if nullif(btrim(coalesce(p ->> 'make', '')), '') is not null and v_make is null then raise exception 'The make needs letters or digits' using errcode = '22023'; end if;
  if v_make is null and v_model is null and v_trim is null and v_body is null then
    raise exception 'A rule needs at least one condition (make, model, trim or body): without one it would match every car' using errcode = '22023';
  end if;
  begin v_class := nullif(p ->> 'class', '')::vehicle_class; exception when others then v_class := null; end;
  if v_class is null then raise exception 'Choose the class' using errcode = '22023'; end if;
  if nullif(p ->> 'aged_years', '') is not null or nullif(p ->> 'aged_class', '') is not null then
    if coalesce(p ->> 'aged_years', '') !~ '^\d{1,2}$' or (p ->> 'aged_years')::integer not between 1 and 60 then raise exception 'Years old is a whole number from 1 to 60' using errcode = '22023'; end if;
    begin v_aged_class := nullif(p ->> 'aged_class', '')::vehicle_class; exception when others then v_aged_class := null; end;
    if v_aged_class is null then raise exception 'Choose the class an older car gets, or leave years old empty' using errcode = '22023'; end if;
    if v_aged_class = v_class then raise exception 'The class of an older car is the same: leave years old empty' using errcode = '22023'; end if;
    v_years := (p ->> 'aged_years')::smallint;
  end if;
  if v_note is null or length(v_note) < 2 or length(v_note) > 200 then raise exception 'The note is 2 to 200 characters: it is shown as the reason for the class' using errcode = '22023'; end if;
  if v_id is null then
    insert into vehicle_class_rules (rank, make_key, model_re, trim_re, body_re, class, aged_years, aged_class, note, is_active)
    values (v_rank, v_make, v_model, v_trim, v_body, v_class, v_years, v_aged_class, v_note, coalesce((p ->> 'is_active')::boolean, true)) returning * into x;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'class_rule_add', 'vehicle_class_rules', x.id::text, app.class_rule_json(x));
  else
    select * into old from vehicle_class_rules where id = v_id for update;
    if old.id is null then raise exception 'Rule not found' using errcode = 'P0002'; end if;
    update vehicle_class_rules set rank = v_rank, make_key = v_make, model_re = v_model, trim_re = v_trim, body_re = v_body, class = v_class, aged_years = v_years,
           aged_class = v_aged_class, note = v_note, is_active = coalesce((p ->> 'is_active')::boolean, is_active)
     where id = v_id returning * into x;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
    values (p_by, 'class_rule_change', 'vehicle_class_rules', x.id::text, app.class_rule_json(old), app.class_rule_json(x));
  end if;
  return app.class_rule_json(x);
end $$;

-- p: {id}
create or replace function app.class_rule_delete(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  old vehicle_class_rules;
begin
  perform app.assert_admin(p_by);
  select * into old from vehicle_class_rules where id = nullif(p ->> 'id', '')::uuid for update;
  if old.id is null then raise exception 'Rule not found' using errcode = 'P0002'; end if;
  delete from vehicle_class_rules where id = old.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before) values (p_by, 'class_rule_delete', 'vehicle_class_rules', old.id::text, app.class_rule_json(old));
  return jsonb_build_object('deleted', true);
end $$;

-- p: {year, make, model, trim, body}: the class a car with these details would get now, and the rule that decided it
create or replace function app.class_rule_test(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r jsonb;
begin
  perform app.assert_admin(p_by);
  if nullif(btrim(coalesce(p ->> 'make', '')), '') is null then raise exception 'Enter the make' using errcode = '22023'; end if;
  r := app.infer_vehicle_class(nullif(p ->> 'year', '')::integer, p ->> 'make', p ->> 'model', nullif(p ->> 'trim', ''), nullif(p ->> 'body', ''));
  return r || jsonb_build_object('class_label', app.class_label(r ->> 'class'));
end $$;

-- ================================================================ 9. a signed car's Management Mode
alter table vehicle_term_changes drop constraint if exists vehicle_term_changes_kind_check;
alter table vehicle_term_changes add constraint vehicle_term_changes_kind_check check (kind in ('fee_notice', 'new_schedule', 'decrease', 'mode_change'));
alter table vehicle_term_changes add column if not exists new_management_mode management_mode;
alter table vehicle_term_changes add column if not exists new_onboarding_method onboarding_method;
alter table vehicle_term_changes add constraint vehicle_term_changes_mode_check check ((kind = 'mode_change') = (new_management_mode is not null));
comment on column vehicle_term_changes.new_management_mode is 'A Management Mode change of a signed car (0165, kind mode_change): the mode from effective_from. awaiting_signature when it is against the owner (the owner signs an updated Vehicle Schedule); noticed when the owner asked for it and nothing is higher (applied on its date by app.job_mode_changes).';

create or replace function app.mode_label(p text) returns text
language sql immutable as $$ select initcap(replace(p, '_', '-')) $$;

-- The vehicle takes the mode of the latest applied change that has started.
create or replace function app.mc_sync_vehicle(p_vehicle uuid) returns boolean
language plpgsql security definer set search_path = public, app as $$
declare
  c vehicle_term_changes;
begin
  select * into c from vehicle_term_changes where vehicle_id = p_vehicle and kind = 'mode_change' and status = 'applied' and effective_from <= app.today()
   order by effective_from desc, applied_at desc limit 1;
  if c.id is null then return false; end if;
  if exists (select 1 from vehicles v where v.id = p_vehicle and (v.management_mode is distinct from c.new_management_mode or v.onboarding_method is distinct from c.new_onboarding_method)) then
    update vehicles set management_mode = c.new_management_mode, onboarding_method = c.new_onboarding_method,
           on_fleet_policy = on_fleet_policy and c.new_management_mode <> 'turo_only' where id = p_vehicle;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (c.applied_by, 'car_mode_applied', 'vehicles', p_vehicle::text, jsonb_build_object('change_id', c.id, 'management_mode', c.new_management_mode, 'effective_from', c.effective_from));
    return true;
  end if;
  return false;
end $$;

-- A noticed change whose date has come (or that needs no notice): the updated Vehicle Schedule is issued, countersigned by
-- CarmaCars under its standing authorization, and the car takes the mode.
create or replace function app.mc_apply(p_change uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  c vehicle_term_changes;
begin
  select * into c from vehicle_term_changes where id = p_change for update;
  if c.id is null or c.kind <> 'mode_change' or c.status <> 'noticed' then raise exception 'This change is not waiting for its date' using errcode = '23514'; end if;
  update vehicle_term_changes set status = 'awaiting_signature' where id = c.id;
  perform app.ot_schedule_change_apply(c.id, c.created_by, now());
  update vehicle_term_changes set countersignature = app.ct_company_signature() where id = c.id;
  perform app.mc_sync_vehicle(c.vehicle_id);
end $$;

-- A signed updated schedule of a mode change carries the new mode; the car takes it from the effective date.
alter function app.ot_schedule_change_apply(uuid, uuid, timestamptz, uuid) rename to ot_schedule_change_apply_pre0165;
create or replace function app.ot_schedule_change_apply(p_change uuid, p_by uuid, p_signed_at timestamptz, p_document uuid default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  c vehicle_term_changes;
  s vehicle_schedules;
  v_new uuid := gen_random_uuid();
  v_hist uuid;
begin
  select * into c from vehicle_term_changes where id = p_change for update;
  if c.kind is distinct from 'mode_change' then return app.ot_schedule_change_apply_pre0165(p_change, p_by, p_signed_at, p_document); end if;
  -- a Management Mode change: the same as 0067's, with the new mode and method on the new schedule (the old row's mode would
  -- fail the schedule's checks: a Self-Managed schedule has no management fee, a Turo-Only one no fees)
  if c.status <> 'awaiting_signature' then raise exception 'This change is not waiting for a signature' using errcode = '23514'; end if;
  -- signed after its date: it applies the day it is signed (a management fee is never back-dated, 0135)
  if app.local_date(coalesce(p_signed_at, now())) > c.effective_from then
    update vehicle_term_changes set effective_from = app.local_date(coalesce(p_signed_at, now())) where id = c.id returning * into c;
  end if;
  select * into s from vehicle_schedules where vehicle_id = c.vehicle_id and superseded_by is null for update;
  if exists (select 1 from vehicle_fee_history h where h.vehicle_id = c.vehicle_id and h.effective_from > c.effective_from) then
    raise exception 'Terms already start after %', c.effective_from using errcode = '23514';
  end if;
  update vehicle_schedules set superseded_by = id where id = s.id;
  insert into vehicle_schedules (id, vehicle_id, owner_agreement_id, title_agreement_id, schedule_number, vehicle_number, is_additional,
      odometer_km, held_by, title_status, finance_party_name, finance_party_account, finance_permission, finance_permission_document_id,
      management_mode, onboarding_method, insurance_fee_cents, tracker_fee_cents, install_fee_cents, revenue_share_bps, enrollment_date,
      special_terms, owners_lien, ppsa_registration_number, onboarding_estimate_cents, document_id, signed_at, created_by, first_last_cents, one_off_fees)
  values (v_new, s.vehicle_id, s.owner_agreement_id, s.title_agreement_id, 'VS-' || nextval('vehicle_schedule_number_seq'), s.vehicle_number, s.is_additional,
      s.odometer_km, s.held_by, s.title_status, s.finance_party_name, s.finance_party_account, s.finance_permission, s.finance_permission_document_id,
      c.new_management_mode, c.new_onboarding_method, c.insurance_fee_cents, c.tracker_fee_cents, coalesce(c.install_fee_cents, s.install_fee_cents), c.revenue_share_bps,
      s.enrollment_date, s.special_terms, s.owners_lien, s.ppsa_registration_number, s.onboarding_estimate_cents, p_document, p_signed_at, p_by,
      coalesce(c.first_last_cents, s.first_last_cents), s.one_off_fees);
  update vehicle_schedules set superseded_by = v_new, superseded_at = now() where id = s.id;
  if exists (select 1 from vehicle_fee_history h where h.vehicle_id = c.vehicle_id) then
    delete from vehicle_fee_history where vehicle_id = c.vehicle_id and effective_from = c.effective_from;
    update vehicle_fee_history set effective_to = c.effective_from
     where vehicle_id = c.vehicle_id and (effective_to is null or effective_to > c.effective_from) and effective_from < c.effective_from;
    insert into vehicle_fee_history (vehicle_id, vehicle_schedule_id, source, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, effective_from, created_by)
    values (c.vehicle_id, v_new, 'signed_schedule', c.insurance_fee_cents, c.tracker_fee_cents, c.revenue_share_bps, c.effective_from, p_by)
    returning id into v_hist;
  end if;
  update vehicle_term_changes set status = 'applied', new_schedule_id = v_new, fee_history_id = v_hist, document_id = coalesce(p_document, document_id),
         applied_by = p_by, applied_at = now()
   where id = c.id;
  perform app.mc_sync_vehicle(c.vehicle_id);
  return v_new;
end $$;
select pg_temp.copy_grants('app.ot_schedule_change_apply(uuid, uuid, timestamptz, uuid)'::regprocedure, 'app.ot_schedule_change_apply_pre0165(uuid, uuid, timestamptz, uuid)'::regprocedure);

-- The text the owner signs says the mode too.
alter function app.schedule_change_text(uuid) rename to schedule_change_text_pre0165;
create or replace function app.schedule_change_text(p_change uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  t jsonb := app.schedule_change_text_pre0165(p_change);
  c vehicle_term_changes;
  v_line text;
begin
  select * into c from vehicle_term_changes where id = p_change;
  if c.kind <> 'mode_change' or t is null then return t; end if;
  v_line := 'Management Mode: ' || app.mode_label(c.new_management_mode::text) || ' (was ' || app.mode_label(c.previous ->> 'management_mode') || ')'
            || coalesce('. Onboarding Method: ' || replace(c.new_onboarding_method::text, '_', ' '), '') || '. The mode applies from ' || app.fmt_day(c.effective_from) || ', or the day this is signed if later.';
  return jsonb_set(jsonb_set(t, '{text}', to_jsonb(replace(t ->> 'text', 'HST is extra.', v_line || E'\n' || 'HST is extra.'))),
                   '{new}', (t -> 'new') || jsonb_build_object('management_mode', c.new_management_mode, 'onboarding_method', c.new_onboarding_method));
end $$;
select pg_temp.copy_grants('app.schedule_change_text(uuid)'::regprocedure, 'app.schedule_change_text_pre0165(uuid)'::regprocedure);

-- p: {vehicle_id, management_mode, onboarding_method, effective_from, reason, owner_requested, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, preview}
create or replace function app.car_mode_change(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  s vehicle_schedules;
  st jsonb;
  std record;
  v_today date := app.today();
  v_days integer := (app.settings()).fee_change_notice_days;
  v_preview boolean := coalesce((p ->> 'preview')::boolean, false);
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_owner_req boolean := coalesce((p ->> 'owner_requested')::boolean, false);
  v_cur_mode management_mode;
  v_cur_method onboarding_method;
  ob vehicle_onboardings;
  v_mode management_mode;
  v_method onboarding_method;
  b_ins bigint; b_trk bigint; b_share integer;
  n_ins bigint; n_trk bigint; n_share integer;
  v_against boolean;
  v_min date;
  v_from date;
  v_lines jsonb := '[]'::jsonb;
  v_steps text[] := '{}';
  v_next date;
  v_change uuid;
  v_edit uuid := gen_random_uuid();
begin
  perform app.assert_admin(p_by);
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid for update;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  if v.supply_type <> 'program_owner' then raise exception 'A % car has no owner terms', lower(app.supply_label(v.supply_type)) using errcode = '23514'; end if;
  if v.is_shareholder_owned then raise exception 'A shareholder-owned car has fixed terms' using errcode = '23514'; end if;
  if v.status in ('declined', 'exited', 'total_loss') then raise exception 'This car is no longer in the program' using errcode = '23514'; end if;
  st := app.ct_now(v.id);
  if st ->> 'state' <> 'signed' then
    raise exception 'The Vehicle Schedule is not signed yet: change the Management Mode in the terms editor, where it applies at once' using errcode = '23514';
  end if;
  select * into s from vehicle_schedules where vehicle_id = v.id and superseded_by is null;
  v_cur_mode := coalesce(v.management_mode, s.management_mode);
  v_cur_method := coalesce(v.onboarding_method, s.onboarding_method);
  begin v_mode := nullif(p ->> 'management_mode', '')::management_mode; exception when others then v_mode := null; end;
  if v_mode is null then raise exception 'Choose the new Management Mode' using errcode = '22023'; end if;
  begin v_method := nullif(p ->> 'onboarding_method', '')::onboarding_method; exception when others then raise exception 'Unknown Onboarding Method' using errcode = '22023'; end;
  if v_method is null then
    v_method := case when v_mode = 'turo_only' then 'none'::onboarding_method
                     when v_cur_method = 'none' then null else v_cur_method end;
  end if;
  if v_method is null then raise exception 'Choose the Onboarding Method for a % car', app.mode_label(v_mode::text) using errcode = '22023'; end if;
  select * into ob from vehicle_onboardings where vehicle_id = v.id;
  perform app.onboarding_plan(s.held_by, s.title_status, v_mode, v_method, coalesce(ob.owners_lien_elected, false));
  if v_mode = v_cur_mode and v_method is not distinct from v_cur_method then
    raise exception 'The car is already % with this Onboarding Method', app.mode_label(v_mode::text) using errcode = '22023';
  end if;
  -- the amounts that go with the new mode (Enrollment Agreement 6): Self-Managed has no management fee, Turo-Only no Fees
  b_ins := (st ->> 'insurance_fee_cents')::bigint; b_trk := (st ->> 'tracker_fee_cents')::bigint; b_share := (st ->> 'revenue_share_bps')::integer;
  select * into std from app.standard_terms(v.owner_id, v_mode);
  n_ins := case when v_mode = 'turo_only' then 0 else coalesce(app.ct_int(p, 'insurance_fee_cents'), case when v_cur_mode = 'turo_only' then std.insurance_fee_cents else b_ins end) end;
  n_trk := case when v_mode = 'turo_only' then 0 else coalesce(app.ct_int(p, 'tracker_fee_cents'), case when v_cur_mode = 'turo_only' then std.tracker_fee_cents else b_trk end) end;
  n_share := case when v_mode in ('turo_only', 'self_managed') then 0 else coalesce(app.ct_int(p, 'revenue_share_bps'), std.revenue_share_bps)::integer end;
  if v_mode = 'turo_only' and (app.ct_int(p, 'insurance_fee_cents') > 0 or app.ct_int(p, 'tracker_fee_cents') > 0 or app.ct_int(p, 'revenue_share_bps') > 0) then
    raise exception 'A Turo-Only car has no Fees, no Tracker and no management fee' using errcode = '23514';
  end if;
  if v_mode = 'self_managed' and app.ct_int(p, 'revenue_share_bps') > 0 then
    raise exception 'A Self-Managed car has no management fee (Revenue Share): the owner is paid 100%% of Owner Revenue' using errcode = '23514';
  end if;
  if n_share > 10000 then raise exception 'The management fee (Revenue Share) is between 0%% and 100%%' using errcode = '22023'; end if;
  v_against := n_ins > b_ins or n_trk > b_trk or n_share > b_share or not v_owner_req;
  v_min := v_today + case when v_against then v_days else 0 end;
  v_from := coalesce(nullif(p ->> 'effective_from', '')::date, v_min);
  if v_from < v_min then
    raise exception 'The earliest date is %: %', app.fmt_day(v_min),
      case when v_against then format('a change the owner did not ask for, or with a higher amount, needs %s days'' written notice', v_days) else 'a change cannot be back-dated' end using errcode = '22023';
  end if;
  if v_from > v_today + 365 then raise exception 'The date is more than a year away' using errcode = '22023'; end if;
  if exists (select 1 from vehicle_term_changes c where c.vehicle_id = v.id and c.status = 'awaiting_signature') then
    raise exception 'An updated Vehicle Schedule is waiting for the owner''s signature. Record it signed or withdraw it first' using errcode = '23514';
  end if;
  if exists (select 1 from vehicle_term_changes c where c.vehicle_id = v.id and c.kind = 'mode_change' and c.status = 'noticed') then
    raise exception 'A Management Mode change is already scheduled. Cancel it first (History), then make the new one' using errcode = '23514';
  end if;
  select min(h.effective_from) into v_next from vehicle_fee_history h where h.vehicle_id = v.id and h.effective_from > v_today;
  if v_next is not null then raise exception 'A change to the fees already starts on %. Cancel it first (History), then make the new one', app.fmt_day(v_next) using errcode = '23514'; end if;
  v_lines := jsonb_build_array(jsonb_build_object('label', 'Management Mode', 'before', app.mode_label(v_cur_mode::text), 'after', app.mode_label(v_mode::text)));
  if v_method is distinct from v_cur_method then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('label', 'Onboarding Method', 'before', replace(coalesce(v_cur_method::text, 'none'), '_', ' '), 'after', replace(v_method::text, '_', ' ')));
  end if;
  if n_ins is distinct from b_ins then v_lines := v_lines || jsonb_build_array(jsonb_build_object('label', app.ct_label('insurance_fee_cents'), 'before', app.ct_fmt('insurance_fee_cents', b_ins), 'after', app.ct_fmt('insurance_fee_cents', n_ins))); end if;
  if n_trk is distinct from b_trk then v_lines := v_lines || jsonb_build_array(jsonb_build_object('label', app.ct_label('tracker_fee_cents'), 'before', app.ct_fmt('tracker_fee_cents', b_trk), 'after', app.ct_fmt('tracker_fee_cents', n_trk))); end if;
  if n_share is distinct from b_share then v_lines := v_lines || jsonb_build_array(jsonb_build_object('label', app.ct_label('revenue_share_bps'), 'before', app.ct_fmt('revenue_share_bps', b_share), 'after', app.ct_fmt('revenue_share_bps', n_share))); end if;
  if v_against then
    v_steps := v_steps || format('The owner is emailed the notice and an updated Vehicle Schedule to sign (Enrollment Agreement 4.8: a change to the schedule is in writing, signed by both parties). The change applies from %s once signed, or from the day they sign if later. Until then the car stays %s.',
                                 app.fmt_day(v_from), app.mode_label(v_cur_mode::text));
  else
    v_steps := v_steps || case when v_from <= v_today
      then format('The owner asked for it and no amount is higher: it applies today. An updated Vehicle Schedule is issued (CarmaCars signs for itself) and the owner is emailed the notice.')
      else format('The owner asked for it and no amount is higher: it applies on %s. The owner is emailed the notice now; the updated Vehicle Schedule is issued that day.', app.fmt_day(v_from)) end;
  end if;
  if v_mode = 'turo_only' and v.on_fleet_policy then
    v_steps := v_steps || 'A Turo-Only car is not on the fleet insurance policy: it is taken off it when the change applies. Tell the insurer.'::text;
  end if;
  if v_preview then
    return jsonb_build_object('lines', v_lines, 'steps', to_jsonb(v_steps), 'needs_signature', v_against, 'earliest', v_min, 'effective_from', v_from, 'done', false,
      'needs_reason', true, 'mode', v_mode, 'method', v_method);
  end if;
  if v_reason is null or length(v_reason) < 3 then raise exception 'Give the reason: the owner reads it in the notice' using errcode = '22023'; end if;
  insert into vehicle_term_changes (vehicle_id, kind, status, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, install_fee_cents, first_last_cents, previous,
                                    notice_sent_on, effective_from, reason, created_by, edit_id, new_management_mode, new_onboarding_method)
  values (v.id, 'mode_change', case when v_against then 'awaiting_signature' else 'noticed' end, n_ins, n_trk, n_share, case when v_mode = 'turo_only' then 0 else s.install_fee_cents end, s.first_last_cents,
          jsonb_build_object('schedule_id', s.id, 'schedule_number', s.schedule_number, 'insurance_fee_cents', b_ins, 'tracker_fee_cents', b_trk, 'revenue_share_bps', b_share,
                             'install_fee_cents', s.install_fee_cents, 'first_last_cents', s.first_last_cents, 'management_mode', v_cur_mode, 'onboarding_method', v_cur_method),
          v_today, v_from, v_reason, p_by, v_edit, v_mode, v_method)
  returning id into v_change;
  perform app.emit_event('owner_mode_change_notice', 'vehicle_term_change', v_change,
    jsonb_build_object('owner_id', v.owner_id, 'vehicle_id', v.id, 'vehicle_name', app.vehicle_name(v.id), 'effective_from', v_from, 'reason', v_reason, 'changes', v_lines,
      'needs_signature', v_against, 'mode_before', v_cur_mode, 'mode_after', v_mode,
      'summary', 'Management Mode ' || app.mode_label(v_cur_mode::text) || ' to ' || app.mode_label(v_mode::text) || ', from ' || app.fmt_day(v_from)),
    'owner_mode_change_notice:' || v_change);
  if not v_against then
    update vehicle_term_changes set applied_by = p_by where id = v_change;
    if v_from <= v_today then perform app.mc_apply(v_change); end if;
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'car_mode_change', 'vehicles', v.id::text, jsonb_build_object('change_id', v_change, 'from', v_cur_mode, 'to', v_mode, 'effective_from', v_from,
                                                                              'needs_signature', v_against, 'owner_requested', v_owner_req, 'reason', v_reason));
  return jsonb_build_object('change_id', v_change, 'lines', v_lines, 'steps', to_jsonb(v_steps), 'needs_signature', v_against, 'effective_from', v_from, 'done', true);
end $$;

-- The date has come for the changes the owner asked for.
create or replace function app.job_mode_changes() returns text
language plpgsql security definer set search_path = public, app as $$
declare
  c record;
  n integer := 0;
  m integer := 0;
begin
  for c in select id from vehicle_term_changes where kind = 'mode_change' and status = 'noticed' and effective_from <= app.today() order by effective_from, created_at loop
    begin
      perform app.mc_apply(c.id);
      n := n + 1;
    exception when others then
      insert into audit_log (action, entity_table, entity_id, after) values ('car_mode_apply_failed', 'vehicle_term_changes', c.id::text, jsonb_build_object('error', sqlerrm));
    end;
  end loop;
  -- a signed change whose date came after the owner signed it
  for c in select distinct vehicle_id from vehicle_term_changes where kind = 'mode_change' and status = 'applied' and effective_from <= app.today() loop
    if app.mc_sync_vehicle(c.vehicle_id) then m := m + 1; end if;
  end loop;
  return format('%s changes applied, %s cars moved to their new mode', n, m);
end $$;

do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron is not available here: the mode change job is not scheduled';
    return;
  end if;
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise warning 'pg_cron could not be created in this database (%): the mode change job is not scheduled', sqlerrm;
    return;
  end;
  perform cron.schedule('carmacars-mode-changes', '11 * * * *', $q$select app.job_mode_changes()$q$);
end $$;

-- ================================================================ 10. the car's terms page: the mode change, in the history and the editor's facts
alter function app.ct_car(uuid, boolean) rename to ct_car_pre0165;
create or replace function app.ct_car(p_vehicle uuid, p_admin boolean) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r jsonb := app.ct_car_pre0165(p_vehicle, p_admin);
  v vehicles;
  s vehicle_schedules;
  v_today date := app.today();
  v_pending record;
  v_opts jsonb := null;
  v_may boolean := false;
begin
  if r is null then return null; end if;
  select * into v from vehicles where id = p_vehicle;
  -- the changes: the mode change has its own wording, and may be cancelled while it has not started
  r := jsonb_set(r, '{changes}', coalesce((
    select jsonb_agg(case when c.kind = 'mode_change' then x || jsonb_build_object('label', 'Management Mode change', 'notice', true,
             'mode_before', c.previous ->> 'management_mode', 'mode_after', c.new_management_mode, 'method_after', c.new_onboarding_method,
             'can_cancel', p_admin and (c.status = 'awaiting_signature' or (c.status = 'noticed' and c.effective_from > v_today)))
           else x end order by (x ->> 'created_at') desc)
      from jsonb_array_elements(r -> 'changes') x left join vehicle_term_changes c on c.id = (x ->> 'id')::uuid), '[]'::jsonb));
  if r ->> 'state' = 'signed' then
    r := r || jsonb_build_object('mode', v.management_mode, 'method', v.onboarding_method);
    select c.new_management_mode as mode, c.effective_from, c.status into v_pending from vehicle_term_changes c
     where c.vehicle_id = p_vehicle and c.kind = 'mode_change' and c.status in ('noticed', 'awaiting_signature')
        or (c.vehicle_id = p_vehicle and c.kind = 'mode_change' and c.status = 'applied' and c.effective_from > v_today)
     order by c.created_at desc limit 1;
    r := r || jsonb_build_object('mode_next', case when v_pending.mode is not null then jsonb_build_object('mode', v_pending.mode, 'from', v_pending.effective_from, 'status', v_pending.status) end);
    if p_admin and v.supply_type = 'program_owner' and not v.is_shareholder_owned and v.status not in ('declined', 'exited', 'total_loss')
       and v_pending.mode is null and not exists (select 1 from vehicle_term_changes c where c.vehicle_id = p_vehicle and c.status = 'awaiting_signature') then
      v_may := true;
      select * into s from vehicle_schedules where vehicle_id = p_vehicle and superseded_by is null;
      v_opts := jsonb_build_object(
        'managed', (select coalesce(jsonb_agg(jsonb_build_object('method', x ->> 'method', 'label', x ->> 'label', 'recommended', (x ->> 'recommended')::boolean)), '[]'::jsonb)
                      from jsonb_array_elements(app.onboarding_options_json(s.held_by::text, s.title_status::text, 'managed')) x),
        'self_managed', (select coalesce(jsonb_agg(jsonb_build_object('method', x ->> 'method', 'label', x ->> 'label', 'recommended', (x ->> 'recommended')::boolean)), '[]'::jsonb)
                      from jsonb_array_elements(app.onboarding_options_json(s.held_by::text, s.title_status::text, 'self_managed')) x),
        'turo_only', (select coalesce(jsonb_agg(jsonb_build_object('method', x ->> 'method', 'label', x ->> 'label', 'recommended', (x ->> 'recommended')::boolean)), '[]'::jsonb)
                      from jsonb_array_elements(app.onboarding_options_json(s.held_by::text, s.title_status::text, 'turo_only')) x));
    end if;
    r := r || jsonb_build_object('mode_change', case when p_admin then jsonb_build_object('may', v_may, 'options', v_opts, 'notice_days', (app.settings()).fee_change_notice_days) end);
  end if;
  return r;
end $$;
select pg_temp.copy_grants('app.ct_car(uuid, boolean)'::regprocedure, 'app.ct_car_pre0165(uuid, boolean)'::regprocedure);

-- ================================================================ 11. the notice document of a mode change
alter function app.ct_notice_text(vehicle_term_changes) rename to ct_notice_text_pre0165;
create or replace function app.ct_notice_text(c vehicle_term_changes) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_days integer := (app.settings(coalesce(c.notice_sent_on, app.local_date(c.created_at)))).fee_change_notice_days;
begin
  if c.kind <> 'mode_change' then return app.ct_notice_text_pre0165(c); end if;
  return to_jsonb(array[
    'This is written notice that the Management Mode of this Vehicle changes from ' || app.mode_label(c.previous ->> 'management_mode') || ' to ' || app.mode_label(c.new_management_mode::text)
      || ', from ' || app.fmt_day(c.effective_from) || ', with the Fees and management fee below (section 6 of the Enrollment Agreement).',
    case when c.status = 'noticed' or (c.status = 'applied' and c.owner_signed_at is null)
      then 'The Owner asked for this change and no amount is higher. CarmaCars issues the updated Vehicle Schedule and signs it for itself.'
      else 'A change to the Vehicle Schedule is in writing and signed by both parties (section 4.8 of the Enrollment Agreement): it applies only once the Owner signs the updated Vehicle Schedule, from the date above or the day it is signed, whichever is later. Until then the current terms stay in place. The Notice Period is ' || v_days || ' days.' end,
    'The Owner may instead take the Vehicle out of the program by written notice of the Notice Period (section 12.1).']);
end $$;

alter function app.pdf_facts(text, text, uuid) rename to pdf_facts_pre0165b;
create or replace function app.pdf_facts(p_kind text, p_key text, p_user uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  f jsonb := app.pdf_facts_pre0165b(p_kind, p_key, p_user);
  c vehicle_term_changes;
begin
  if p_kind <> 'terms_notice' or f is null then return f; end if;
  select * into c from vehicle_term_changes where id = app.file_key_id(p_key);
  if c.kind <> 'mode_change' then return f; end if;
  return f || jsonb_build_object('title', 'Notice of a change of Management Mode',
    'lines', jsonb_build_array(jsonb_build_object('label', 'Management Mode', 'before', app.mode_label(c.previous ->> 'management_mode'), 'after', app.mode_label(c.new_management_mode::text)))
             || (f -> 'lines'));
end $$;
select pg_temp.copy_grants('app.pdf_facts(text, text, uuid)'::regprocedure, 'app.pdf_facts_pre0165b(text, text, uuid)'::regprocedure);

-- ================================================================ 12. a change that had not started is cancelled: the owner is told
alter function app.car_terms_cancel(uuid, jsonb) rename to car_terms_cancel_pre0165;
create or replace function app.car_terms_cancel(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c vehicle_term_changes;
  v vehicles;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_res jsonb;
  v_lines jsonb := '[]'::jsonb;
  f text;
begin
  perform app.assert_admin(p_by);
  select * into c from vehicle_term_changes where id = nullif(p ->> 'change_id', '')::uuid for update;
  if c.id is null then raise exception 'Not found' using errcode = 'P0002'; end if;
  if c.kind = 'mode_change' and c.status = 'noticed' then
    if v_reason is null then raise exception 'Give the reason' using errcode = '22023'; end if;
    if c.effective_from <= app.today() then raise exception 'Only a change that has not started yet can be cancelled' using errcode = '23514'; end if;
    update vehicle_term_changes set status = 'cancelled', cancelled_reason = v_reason where id = c.id;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'car_terms_cancel', 'vehicle_term_changes', c.id::text, jsonb_build_object('reason', v_reason, 'effective_from', c.effective_from, 'kind', c.kind));
    v_res := jsonb_build_object('cancelled', true);
  else
    v_res := app.car_terms_cancel_pre0165(p_by, p);
  end if;
  -- the owner is told: what was going to change, and that their terms stay as they are
  select * into v from vehicles where id = c.vehicle_id;
  if c.kind = 'mode_change' then
    v_lines := jsonb_build_array(jsonb_build_object('label', 'Management Mode', 'before', app.mode_label(c.previous ->> 'management_mode'), 'after', app.mode_label(c.new_management_mode::text)));
  end if;
  foreach f in array array['insurance_fee_cents', 'tracker_fee_cents', 'revenue_share_bps'] loop
    if (c.previous ->> f) is distinct from (case f when 'insurance_fee_cents' then c.insurance_fee_cents when 'tracker_fee_cents' then c.tracker_fee_cents else c.revenue_share_bps end)::text then
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('label', app.ct_label(f), 'before', app.ct_fmt(f, (c.previous ->> f)::bigint),
        'after', app.ct_fmt(f, (case f when 'insurance_fee_cents' then c.insurance_fee_cents when 'tracker_fee_cents' then c.tracker_fee_cents else c.revenue_share_bps end)::bigint)));
    end if;
  end loop;
  perform app.emit_event('owner_fee_change_cancelled', 'vehicle_term_change', c.id,
    jsonb_build_object('owner_id', v.owner_id, 'vehicle_id', v.id, 'vehicle_name', app.vehicle_name(v.id), 'effective_from', c.effective_from, 'changes', v_lines,
      'kind', c.kind, 'was_awaiting_signature', c.status = 'awaiting_signature',
      'summary', coalesce((select string_agg((x ->> 'label') || ' ' || (x ->> 'before') || ' to ' || (x ->> 'after'), '; ') from jsonb_array_elements(v_lines) x), 'the change to your terms')),
    'owner_fee_change_cancelled:' || c.id);
  return v_res;
end $$;
select pg_temp.copy_grants('app.car_terms_cancel(uuid, jsonb)'::regprocedure, 'app.car_terms_cancel_pre0165(uuid, jsonb)'::regprocedure);

-- ================================================================ 13. the emails
insert into notification_link_paths (key, path) values ('field_hours', '/field/hours') on conflict (key) do update set path = excluded.path;

-- The field staff member themself, at their own address (an active staff account only).
alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_pre0165;
create function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_c.code = 'staff_pay_statement' then
    return query select 'staff_field'::text, u.id, u.email, u.full_name, null::uuid, null::uuid, true
                   from users u join staff_profiles sp on sp.user_id = u.id
                  where u.id = (p_event.payload ->> 'staff_id')::uuid and sp.staff_type = 'field' and u.email is not null;
    return;
  end if;
  return query select * from app.notification_recipients_pre0165(p_event, p_c);
end $$;
select pg_temp.copy_grants('app.notification_recipients(app_events, notification_catalogue)'::regprocedure, 'app.notification_recipients_pre0165(app_events, notification_catalogue)'::regprocedure);

alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0165;
create function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_pre0165(p_code, p_event, p_to);
  p jsonb := coalesce(p_event.payload, '{}'::jsonb);
  l field_pay_lines;
  r field_pay_runs;
  po staff_commission_payouts;
begin
  if p_code in ('owner_mode_change_notice', 'owner_fee_change_cancelled') then
    x := coalesce(x, '{}'::jsonb) || jsonb_build_object('effective_date', app.fmt_day((p ->> 'effective_from')::date),
      'fee_changes', coalesce(p -> 'changes', '[]'::jsonb), 'fee_change_summary', coalesce(p ->> 'summary', ''),
      'fee_change_reason', coalesce(nullif(p ->> 'reason', ''), ''), 'needs_signature', coalesce((p ->> 'needs_signature')::boolean, false),
      'mode_before', app.mode_label(coalesce(p ->> 'mode_before', '')), 'mode_after', app.mode_label(coalesce(p ->> 'mode_after', '')),
      'notice_period_days', (app.settings()).notice_period_days::text,
      'vehicle_name', coalesce(p ->> 'vehicle_name', x ->> 'vehicle_name', ''), 'vehicle_id', coalesce(p ->> 'vehicle_id', x ->> 'vehicle_id', ''));
  elsif p_code = 'staff_pay_statement' then
    select * into l from field_pay_lines where id = p_event.entity_id;
    select * into r from field_pay_runs where id = l.run_id;
    select * into po from staff_commission_payouts where id = l.payout_id;
    x := coalesce(x, '{}'::jsonb) || jsonb_build_object(
      'first_name', coalesce(nullif(x ->> 'first_name', ''), (select split_part(u.full_name, ' ', 1) from users u where u.id = l.staff_id), 'there'),
      'period_label', app.fp_period_label(r.period_start), 'statement_number', coalesce(l.statement_number, ''),
      'gross_total', app.fmt_money(l.gross_cents), 'hours_total', app.fp_hours_text(l.minutes_total),
      'payout_method', case l.method when 'e_transfer' then 'e-Transfer' when 'bank_transfer' then 'Bank transfer' when 'cash' then 'Cash' else 'Not paid yet' end,
      'payout_date', coalesce(to_char(l.paid_on, 'FMMonth FMDD, YYYY'), ''), 'payout_reference', coalesce(l.reference, ''),
      'pay_lines', (select jsonb_agg(z) from (
          select jsonb_build_object('what', 'Hours: ' || app.fp_hours_text(l.minutes_regular) || ' at ' || app.fmt_money(l.rate_cents), 'amount', app.fmt_money(l.wage_cents)) as z
          union all select jsonb_build_object('what', 'Overtime: ' || app.fp_hours_text(l.minutes_overtime), 'amount', app.fmt_money(l.overtime_cents)) where l.minutes_overtime > 0
          union all select jsonb_build_object('what', 'Commissions', 'amount', app.fmt_money(l.commission_cents)) where l.commission_cents > 0
          union all select jsonb_build_object('what', 'Vacation pay', 'amount', app.fmt_money(l.vacation_cents)) where l.vacation_cents > 0) q),
      'hours_url', app.ntf_link('field_hours'));
  end if;
  return x;
end $$;
select pg_temp.copy_grants('app.notification_payload(text, app_events, jsonb)'::regprocedure, 'app.ntf_payload_pre0165(text, app_events, jsonb)'::regprocedure);

-- CATALOGUE 0165 START (generated by supabase/seed/0165_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('owner_mode_change_notice', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Notice of a change to the Management Mode of your {{vehicle_name}}, from {{effective_date}}', '{{fee_change_summary}}', 'Immediate: at least the Notice Period (30 days by default) before the date of a change against the owner; on the day it is made for a change the owner asked for', 'An Admin changes the Management Mode of a car whose Vehicle Schedule is signed (migration 0165; the car page, Management Mode). When the change is against the owner (a higher fee or management fee, or a change CarmaCars starts) the owner signs an updated Vehicle Schedule and the date is at least the Notice Period ahead (needs_signature is true); when the owner asked for it and no amount is higher, the change is dated and applied by CarmaCars on that date. One email per change.', null, '/owner/agreements', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"effective_date","type":"string"},{"name":"fee_change_reason","type":"string"},{"name":"fee_change_summary","type":"string"},{"name":"fee_changes","type":"list","fields":["label","before","after"]},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"mode_after","type":"string"},{"name":"mode_before","type":"string"},{"name":"needs_signature","type":"boolean"},{"name":"notice_period_days","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_id","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_mode_change_notice.html', 'templates/owner_mode_change_notice.txt'),
  ('owner_fee_change_cancelled', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'The change to your terms for the {{vehicle_name}} is cancelled', 'Your terms stay as they are: {{fee_change_summary}}.', 'Immediate', 'An Admin cancels a change to a car''s terms that had not started yet (migration 0165; History on the car page or the owner''s terms): a higher or lower Insurance Fee, Tracker Fee or management fee noticed in writing, a Management Mode change, or an updated Vehicle Schedule that was waiting for the owner''s signature. One email per cancelled change, saying what was going to change and that the terms stay as they are.', null, '/owner/vehicles/{{vehicle_id}}', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"effective_date","type":"string"},{"name":"fee_change_summary","type":"string"},{"name":"fee_changes","type":"list","fields":["label","before","after"]},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_id","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_fee_change_cancelled.html', 'templates/owner_fee_change_cancelled.txt'),
  ('staff_pay_statement', 'staff_field', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Your pay statement: {{period_label}}', '{{gross_total}}, {{payout_method}}, {{payout_date}}.', 'Immediate', 'An Admin records the payment of a field staff member''s pay for a two-week pay period (Admin > Money > Field pay > Pay run > Record the payment; migration 0165), or sends the statement again. One email to that staff member, at their own address, with the figures of their pay statement (the PDF is in My hours).', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"gross_total","type":"string"},{"name":"hours_total","type":"string"},{"name":"hours_url","type":"url"},{"name":"pay_lines","type":"list","fields":["what","amount"]},{"name":"payout_date","type":"string"},{"name":"payout_method","type":"string"},{"name":"payout_reference","type":"string"},{"name":"period_label","type":"string"},{"name":"statement_number","type":"string"}]'::jsonb, 'templates/staff_pay_statement.html', 'templates/staff_pay_statement.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0165 END
-- the refresh above recomputes consent rules: the promo expiry reminders (0161) need express consent
update notification_catalogue set consent_rule = 'express' where code in ('renter_promo_expiry_3d', 'renter_promo_expiry_1d');
update notification_catalogue set emitted_by = 'app.car_mode_change (0165)' where code = 'owner_mode_change_notice';
update notification_catalogue set emitted_by = 'app.car_terms_cancel (0165)' where code = 'owner_fee_change_cancelled';
update notification_catalogue set emitted_by = 'app.field_pay_line_paid, app.field_pay_line_email (0165)' where code = 'staff_pay_statement';

insert into sms_templates (code, label, body, urgent, sort_order) values
  ('owner_mode_change_notice', 'Owner: change of Management Mode', 'CarmaCars: notice of a change to the Management Mode of your {{vehicle_name}}, from {{effective_date}}. Read it: {{link}}', false, 238),
  ('owner_fee_change_cancelled', 'Owner: change to terms cancelled', 'CarmaCars: the change to your terms for the {{vehicle_name}} is cancelled. Your terms stay as they are: {{link}}', false, 239)
on conflict (code) do nothing;

-- ================================================================ 14. the door
-- Field hours (the field portal's own, and Fleet's and Admin's), the pay run (Admin), the class rules (Admin) and the car's
-- Management Mode (Admin). Each function checks the person again.
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0165;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if p_call = 'ops_read' and p_name in ('field_hours', 'field_pay', 'field_pay_csv', 'class_rules') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'field_hours' then app.field_hours_read(p_user, p_) when 'field_pay' then app.field_pay_read(p_user, p_)
                       when 'field_pay_csv' then app.field_pay_csv(p_user, p_) else app.class_rules_read(p_user) end;
  end if;
  if p_call = 'ops_do' and p_name in ('field_clock_in', 'field_clock_out', 'field_shift_add', 'field_shift_edit', 'field_shift_void', 'field_pay_rate_set',
       'field_pay_run_start', 'field_pay_run_refresh', 'field_pay_run_approve', 'field_pay_run_void', 'field_pay_line_paid', 'field_pay_line_email',
       'class_rule_save', 'class_rule_delete', 'class_rule_test', 'car_mode_change') then
    perform app.door_begin(p_user, p_aal);
    return case p_name
      when 'field_clock_in' then app.field_clock_in(p_user, p_) when 'field_clock_out' then app.field_clock_out(p_user, p_)
      when 'field_shift_add' then app.field_shift_add(p_user, p_) when 'field_shift_edit' then app.field_shift_edit(p_user, p_) when 'field_shift_void' then app.field_shift_void(p_user, p_)
      when 'field_pay_rate_set' then app.field_pay_rate_set(p_user, p_)
      when 'field_pay_run_start' then app.field_pay_run_start(p_user, p_) when 'field_pay_run_refresh' then app.field_pay_run_refresh(p_user, p_)
      when 'field_pay_run_approve' then app.field_pay_run_approve(p_user, p_) when 'field_pay_run_void' then app.field_pay_run_void(p_user, p_)
      when 'field_pay_line_paid' then app.field_pay_line_paid(p_user, p_) when 'field_pay_line_email' then app.field_pay_line_email(p_user, p_)
      when 'class_rule_save' then app.class_rule_save(p_user, p_) when 'class_rule_delete' then app.class_rule_delete(p_user, p_)
      when 'class_rule_test' then app.class_rule_test(p_user, p_) else app.car_mode_change(p_user, p_) end;
  end if;
  return app.door_pre0165(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0165(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 15. grants of the new functions
select pg_temp.service_only(p.oid::regprocedure)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'app' and p.proname = any (array['fp_period', 'fp_rate', 'fp_locked', 'field_shift_guard', 'fp_figures', 'fp_commissions', 'fp_line_values', 'fp_hours_text', 'fp_period_label',
         'fp_may_edit_hours', 'fp_shift_jobs', 'fp_shift_json', 'fp_shift_state', 'field_clock_in', 'field_clock_out', 'field_shift_add', 'field_shift_edit', 'field_shift_void',
         'field_pay_rate_set', 'fp_run_refresh', 'field_pay_run_start', 'field_pay_run_refresh', 'field_pay_run_approve', 'field_pay_run_void', 'field_pay_line_paid',
         'field_pay_line_email', 'fp_line_json', 'field_pay_read', 'field_hours_read', 'field_pay_csv', 'class_rule_json', 'class_rules_read', 'class_rule_pattern',
         'class_rule_save', 'class_rule_delete', 'class_rule_test', 'mode_label', 'mc_sync_vehicle', 'mc_apply', 'car_mode_change', 'job_mode_changes']);

-- ================================================================ 16. the guides
-- GUIDES 0165 START (generated by supabase/seed/0165_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('admin', 'getting-around-admin', 'chapter', 'start-here', 'Admin opens on To do: the day''s counts at the top, then what needs you now, most urgent first. The menu groups every screen into six groups: Today, Bookings, Cars, People, Money and Settings. The long groups come in labelled parts (for example People: Owners and partners, then Renters, staff and investors). Search finds any booking, car or person, and Ctrl+K jumps to any page.

## To do

Start every shift here. Each line says what to do and why, and its button opens a small pop-up that does it, already filled in. Nothing to remember and no menu to search.

1. Each piece of work is its own line (work of one kind for several cars is one line, such as Add real photos (72 cars); its button opens the list), marked Now, Today or When you can: a car the insurer has not confirmed, a car not on the site, a renter''s documents to check, a visitor waiting in live chat, a booking request, a change a renter asked for, an owner application, an owner invoice waiting for payment, the first and last month an owner paid after their invoices were voided, the terms agreed with an owner still on the standard grid, documents an owner has not signed, an official form to check, a plate to check, a car showing sample photos, and any task of the Admin.
2. Press the line''s button: Mark insured, Set rates and publish, Review documents, Record payment, Record what they paid, Enter the terms, Record paper signature, Checked: use for owners, Open the chat, and so on. A line you do not need has Not needed or These are correct. The pop-up is filled in; check it and confirm. The line disappears once the work is done.
3. Under the lines, the counts with one button each (failed payments, agreements to countersign, tolls, listings, insurance, staff commissions, prices typed by hand, sales claims, Turo emails). A count with nothing waiting moves to the bottom, under "more with nothing waiting".
4. While no assistant holds customer service, sales, finance or fleet (the live verification''s test accounts do not count), their tasks come to To do too, and so do their emails, to rent@carmacars.ca.
5. Beside the list (under it on a phone): today''s pickups (ready or not ready), today''s returns (due or late) and today''s chauffeur bookings, by time.
6. Press **Overview** for the money, fleet and queue figures, the alerts and the team''s sales for the month.
7. The dark band at the top counts the day, each count one tap from its page: requests waiting (with how long the oldest has waited, red past the reply target), pickups and returns today, payments to chase, deposits to settle, staff tasks open and alerts. A count that needs you now is red and says so.

![](/guides/img/admin-01-today-desktop-ea48309c.jpg "desktop; size: 1440 900; address: carmacars.ca/admin; pins: 1 22.6 31.6, 2 90.3 31.7, 3 18.4 90.2, 4 94.4 22.2")

## The menu

The current group is open, with its pages; press another group to open it. On a phone the whole menu sits behind one Menu button that says where you are.

| Group | Pages |
| --- | --- |
| Today | To do, Overview, Staff tasks, Live visitors |
| Bookings | Trips: Requests, Bookings, Calendar, Add a rental, Chauffeur. Customers: Live chat, Renter leads, Reviews. Problems: Damage, Incidents and claims |
| Cars | Vehicles, Listings, Maintenance, Rates for many cars, Calendar sync, Similar cars, Retire or delete |
| Money | Owners: Owner invoices, Owner debits, Owner statements, Payouts. Renters: Payments by day, Payments and refunds, Tolls and tickets. Company: Company statements, Reconciliation, Expenses, Insurer invoices, Staff commissions |
| People | Owners and partners: Applications, Owners, Add a car for an owner, Partners, Owner forms, Paid and signed. Renters, staff and investors: Renters, Staff, Investors, Portals and view as |
| Settings | All settings. Website: Site, Vehicle pages, Sample photos, Add-ons, Discount games, Guides. Rules: Program, Forms, Maintenance, Emails. Records: Email log, Audit log |

![On a phone: press Menu (1), then a group (2), then the page (3).](/guides/img/admin-31-menu-phone-667dc2fd.jpg "phone; size: 390 715; pins: 1 10.3 28.7, 2 76.9 42.4, 3 76.9 48.3")

## Search

The search box sits at the top of the menu, on every page.

1. Type a booking number (CC-1042), a car code (CC-7F3A, on every car page and fleet card), a plate, a VIN, or a name or email address.
2. Press **Search** (or Enter). Results come in groups: bookings, cars, owners, partners and renters. Open one to go to its page.
3. To go to a page instead, press Ctrl+K (Cmd+K on a Mac) or **Jump to a page** under the search box, type a few letters (Payouts, Program settings) and press Enter. The first line searches the records for what you typed.

![](/guides/img/admin-32-search-desktop-ca548a70.jpg "desktop; size: 1440 420; address: carmacars.ca/admin/search?q=CC-10057; pins: 1 7.4 45.2, 2 95.0 46.9")

## Keyboard shortcuts

Press g, then a letter. Press / to jump to the search box, and Ctrl+K to jump to any page.

| Keys | Opens | Keys | Opens |
| --- | --- | --- | --- |
| g t | To do | g v | Vehicles |
| g r | Requests | g l | Listings |
| g b | Bookings | g a | Applications |
| g c | Calendar | g o | Owners |
| g k | Staff tasks | g m | Payments and refunds |
| g s | All settings | / | Search |
| Ctrl K | Jump to a page | Esc | Close it |
', 'Getting around Admin', 'To do, the menu, search, keyboard shortcuts and your other portals.',
  'Admin opens on To do: the day''s counts at the top, then what needs you now, most urgent first. The menu groups every screen into six groups: Today, Bookings, Cars, People, Money and Settings. The long groups come in labelled parts (for example People: Owners and partners, then Renters, staff and investors). Search finds any booking, car or person, and Ctrl+K jumps to any page.

## To do

Start every shift here. Each line says what to do and why, and its button opens a small pop-up that does it, already filled in. Nothing to remember and no menu to search.

1. Each piece of work is its own line (work of one kind for several cars is one line, such as Add real photos (72 cars); its button opens the list), marked Now, Today or When you can: a car the insurer has not confirmed, a car not on the site, a renter''s documents to check, a visitor waiting in live chat, a booking request, a change a renter asked for, an owner application, an owner invoice waiting for payment, the first and last month an owner paid after their invoices were voided, the terms agreed with an owner still on the standard grid, documents an owner has not signed, an official form to check, a plate to check, a car showing sample photos, and any task of the Admin.
2. Press the line''s button: Mark insured, Set rates and publish, Review documents, Record payment, Record what they paid, Enter the terms, Record paper signature, Checked: use for owners, Open the chat, and so on. A line you do not need has Not needed or These are correct. The pop-up is filled in; check it and confirm. The line disappears once the work is done.
3. Under the lines, the counts with one button each (failed payments, agreements to countersign, tolls, listings, insurance, staff commissions, prices typed by hand, sales claims, Turo emails). A count with nothing waiting moves to the bottom, under "more with nothing waiting".
4. While no assistant holds customer service, sales, finance or fleet (the live verification''s test accounts do not count), their tasks come to To do too, and so do their emails, to rent@carmacars.ca.
5. Beside the list (under it on a phone): today''s pickups (ready or not ready), today''s returns (due or late) and today''s chauffeur bookings, by time.
6. Press **Overview** for the money, fleet and queue figures, the alerts and the team''s sales for the month.
7. The dark band at the top counts the day, each count one tap from its page: requests waiting (with how long the oldest has waited, red past the reply target), pickups and returns today, payments to chase, deposits to settle, staff tasks open and alerts. A count that needs you now is red and says so.

![](/guides/img/admin-01-today-desktop-ea48309c.jpg "desktop; size: 1440 900; address: carmacars.ca/admin; pins: 1 22.6 31.6, 2 90.3 31.7, 3 18.4 90.2, 4 94.4 22.2")

## The menu

The current group is open, with its pages; press another group to open it. On a phone the whole menu sits behind one Menu button that says where you are.

| Group | Pages |
| --- | --- |
| Today | To do, Overview, Staff tasks, Live visitors |
| Bookings | Trips: Requests, Bookings, Calendar, Add a rental, Chauffeur. Customers: Live chat, Renter leads, Reviews. Problems: Damage, Incidents and claims |
| Cars | Vehicles, Listings, Maintenance, Rates for many cars, Calendar sync, Similar cars, Retire or delete |
| Money | Owners: Owner invoices, Owner debits, Owner statements, Payouts. Renters: Payments by day, Payments and refunds, Tolls and tickets. Company: Company statements, Reconciliation, Expenses, Insurer invoices, Staff commissions, Field pay |
| People | Owners and partners: Applications, Owners, Add a car for an owner, Partners, Owner forms, Paid and signed. Renters, staff and investors: Renters, Staff, Investors, Portals and view as |
| Settings | All settings. Website: Site, Vehicle pages, Sample photos, Add-ons, Discount games, Guides. Rules: Program, Forms, Maintenance, Emails. Records: Email log, Audit log |

![On a phone: press Menu (1), then a group (2), then the page (3).](/guides/img/admin-31-menu-phone-667dc2fd.jpg "phone; size: 390 715; pins: 1 10.3 28.7, 2 76.9 42.4, 3 76.9 48.3")

## Search

The search box sits at the top of the menu, on every page.

1. Type a booking number (CC-1042), a car code (CC-7F3A, on every car page and fleet card), a plate, a VIN, or a name or email address.
2. Press **Search** (or Enter). Results come in groups: bookings, cars, owners, partners and renters. Open one to go to its page.
3. To go to a page instead, press Ctrl+K (Cmd+K on a Mac) or **Jump to a page** under the search box, type a few letters (Payouts, Program settings) and press Enter. The first line searches the records for what you typed.

![](/guides/img/admin-32-search-desktop-ca548a70.jpg "desktop; size: 1440 420; address: carmacars.ca/admin/search?q=CC-10057; pins: 1 7.4 45.2, 2 95.0 46.9")

## Keyboard shortcuts

Press g, then a letter. Press / to jump to the search box, and Ctrl+K to jump to any page.

| Keys | Opens | Keys | Opens |
| --- | --- | --- | --- |
| g t | To do | g v | Vehicles |
| g r | Requests | g l | Listings |
| g b | Bookings | g a | Applications |
| g c | Calendar | g o | Owners |
| g k | Staff tasks | g m | Payments and refunds |
| g s | All settings | / | Search |
| Ctrl K | Jump to a page | Esc | Close it |
',
  '<p class="gd-p">Admin opens on To do: the day&#39;s counts at the top, then what needs you now, most urgent first. The menu groups every screen into six groups: Today, Bookings, Cars, People, Money and Settings. The long groups come in labelled parts (for example People: Owners and partners, then Renters, staff and investors). Search finds any booking, car or person, and Ctrl+K jumps to any page.</p><section class="gd-task" id="getting-around-admin-to-do" data-gd-task><h2 class="gd-h2">To do</h2><p class="gd-p">Start every shift here. Each line says what to do and why, and its button opens a small pop-up that does it, already filled in. Nothing to remember and no menu to search.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each piece of work is its own line (work of one kind for several cars is one line, such as Add real photos (72 cars); its button opens the list), marked Now, Today or When you can: a car the insurer has not confirmed, a car not on the site, a renter&#39;s documents to check, a visitor waiting in live chat, a booking request, a change a renter asked for, an owner application, an owner invoice waiting for payment, the first and last month an owner paid after their invoices were voided, the terms agreed with an owner still on the standard grid, documents an owner has not signed, an official form to check, a plate to check, a car showing sample photos, and any task of the Admin.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press the line&#39;s button: Mark insured, Set rates and publish, Review documents, Record payment, Record what they paid, Enter the terms, Record paper signature, Checked: use for owners, Open the chat, and so on. A line you do not need has Not needed or These are correct. The pop-up is filled in; check it and confirm. The line disappears once the work is done.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Under the lines, the counts with one button each (failed payments, agreements to countersign, tolls, listings, insurance, staff commissions, prices typed by hand, sales claims, Turo emails). A count with nothing waiting moves to the bottom, under &quot;more with nothing waiting&quot;.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">While no assistant holds customer service, sales, finance or fleet (the live verification&#39;s test accounts do not count), their tasks come to To do too, and so do their emails, to rent@carmacars.ca.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Beside the list (under it on a phone): today&#39;s pickups (ready or not ready), today&#39;s returns (due or late) and today&#39;s chauffeur bookings, by time.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Press <b class="gd-ui">Overview</b> for the money, fleet and queue figures, the alerts and the team&#39;s sales for the month.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">The dark band at the top counts the day, each count one tap from its page: requests waiting (with how long the oldest has waited, red past the reply target), pickups and returns today, payments to chase, deposits to settle, staff tasks open and alerts. A count that needs you now is red and says so.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-01-today-desktop-ea48309c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:22.6%;top:31.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:90.3%;top:31.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:18.4%;top:90.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:94.4%;top:22.2%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="getting-around-admin-the-menu" data-gd-task><h2 class="gd-h2">The menu</h2><p class="gd-p">The current group is open, with its pages; press another group to open it. On a phone the whole menu sits behind one Menu button that says where you are.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Group</th><th scope="col">Pages</th></tr></thead><tbody><tr><td>Today</td><td>To do, Overview, Staff tasks, Live visitors</td></tr><tr><td>Bookings</td><td>Trips: Requests, Bookings, Calendar, Add a rental, Chauffeur. Customers: Live chat, Renter leads, Reviews. Problems: Damage, Incidents and claims</td></tr><tr><td>Cars</td><td>Vehicles, Listings, Maintenance, Rates for many cars, Calendar sync, Similar cars, Retire or delete</td></tr><tr><td>Money</td><td>Owners: Owner invoices, Owner debits, Owner statements, Payouts. Renters: Payments by day, Payments and refunds, Tolls and tickets. Company: Company statements, Reconciliation, Expenses, Insurer invoices, Staff commissions, Field pay</td></tr><tr><td>People</td><td>Owners and partners: Applications, Owners, Add a car for an owner, Partners, Owner forms, Paid and signed. Renters, staff and investors: Renters, Staff, Investors, Portals and view as</td></tr><tr><td>Settings</td><td>All settings. Website: Site, Vehicle pages, Sample photos, Add-ons, Discount games, Guides. Rules: Program, Forms, Maintenance, Emails. Records: Email log, Audit log</td></tr></tbody></table></div><div class="gd-figblock"><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/715"><img src="/guides/img/admin-31-menu-phone-667dc2fd.jpg" alt="On a phone: press Menu (1), then a group (2), then the page (3)." loading="lazy" decoding="async" width="390" height="715"><span class="gd-pin" style="left:10.3%;top:28.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:76.9%;top:42.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:76.9%;top:48.3%" aria-hidden="true">3</span></div></div><figcaption>On a phone: press Menu (1), then a group (2), then the page (3).</figcaption></figure></div></section><section class="gd-task" id="getting-around-admin-search" data-gd-task><h2 class="gd-h2">Search</h2><p class="gd-p">The search box sits at the top of the menu, on every page.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type a booking number (CC-1042), a car code (CC-7F3A, on every car page and fleet card), a plate, a VIN, or a name or email address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Search</b> (or Enter). Results come in groups: bookings, cars, owners, partners and renters. Open one to go to its page.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To go to a page instead, press Ctrl+K (Cmd+K on a Mac) or <b class="gd-ui">Jump to a page</b> under the search box, type a few letters (Payouts, Program settings) and press Enter. The first line searches the records for what you typed.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/search?q=CC-10057</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/420"><img src="/guides/img/admin-32-search-desktop-ca548a70.jpg" alt="" loading="lazy" decoding="async" width="1440" height="420"><span class="gd-pin" style="left:7.4%;top:45.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:95%;top:46.9%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="getting-around-admin-keyboard-shortcuts" data-gd-task><h2 class="gd-h2">Keyboard shortcuts</h2><p class="gd-p">Press g, then a letter. Press / to jump to the search box, and Ctrl+K to jump to any page.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Keys</th><th scope="col">Opens</th><th scope="col">Keys</th><th scope="col">Opens</th></tr></thead><tbody><tr><td>g t</td><td>To do</td><td>g v</td><td>Vehicles</td></tr><tr><td>g r</td><td>Requests</td><td>g l</td><td>Listings</td></tr><tr><td>g b</td><td>Bookings</td><td>g a</td><td>Applications</td></tr><tr><td>g c</td><td>Calendar</td><td>g o</td><td>Owners</td></tr><tr><td>g k</td><td>Staff tasks</td><td>g m</td><td>Payments and refunds</td></tr><tr><td>g s</td><td>All settings</td><td>/</td><td>Search</td></tr><tr><td>Ctrl K</td><td>Jump to a page</td><td>Esc</td><td>Close it</td></tr></tbody></table></div></section>');
select app.guide_release_section('admin', 'owners-and-onboarding', 'chapter', 'chauffeur-service', 'Owners apply on the site with List your car. Every application waits for you in one place, Applications: approve it, ask the owner for something, or decline it. Approved owners sign and pay in their portal.

## Applications

**People** > **Applications**. Every owner application, newest first.

1. The chips filter by status: New, Waiting on owner, Approved, Declined, or All. New applications also show on To do.
2. Each row shows the application number, the owner, the car, how many of the four checks are done, and when they applied.
3. Open an application to decide.

![](/guides/img/admin-33-applications-desktop-152f9e34.jpg "desktop; size: 1440 640; address: carmacars.ca/admin/applications; pins: 1 36.8 39.7, 2 48.6 53.1, 3 19.8 53.1")

## Decide on an application

One page holds everything: the owner, the car, the uploads, the four checks and the notes.

1. Check the driver''s licence, the ownership, the insurance and the lender or lessor. Mark each one Checked, fine, Problem or Not needed.
2. Press **Approve**. The step "Terms and first invoice" opens for each car, filled in with the owner''s negotiated terms (or the standard grid): Insurance Fee, Tracker Fee, management fee (Revenue Share), Install Fee and the first and last month amount (2 x the Insurance Fee unless you type an exact amount). Change any of them to the cent; with several cars, **Use these terms for every car** copies the first car''s numbers to the others.
3. Choose the invoices: First and last month, Registration fee (any exact amount), Tracker install (only once trackers are available) and Another invoice. For each one choose Send now, Save as draft or Already paid. Already paid asks how (e-Transfer, cash, cheque, bank transfer or other), the date and the reference: it is recorded like Record payment and the owner gets the receipt, not an invoice.
4. Press **Approve** at the bottom of the step. Nothing is set or sent before that. The owner becomes active, the documents open for one signature in their portal, only the invoices you chose are made, and the owner gets one email.
5. Missing something? Press **Ask for something**, tick what you need (for example the ownership permit or the insurance slip), add a message if you like, and press **Send to the owner**. The owner gets an email and a task in their portal; the application shows Waiting on owner until they answer.
6. Not a fit? Press **Decline**, write the Reason the owner reads, and press **Decline the application**. The owner is emailed for each car.

![](/guides/img/admin-34-application-desktop-98b64f92.jpg "desktop; size: 1440 812; address: carmacars.ca/admin/applications/166e487a-11a1-4433-b1ca-8c2bc14bf5ca; pins: 1 72.9 67.1, 2 73.9 42.9, 3 84.7 42.9, 4 72.9 49.6")

The application has an Invoices tab: every invoice of its cars, drafts and voids included. An application staff entered for the owner says "Entered by staff" and who; approving it sends the owner the set-up email (review the details and sign) instead of the approval email.

> Tip: Notes on the page are for staff only: **Add note** keeps a line on the record. When the owner answers a request, their answer is in the notes and the application is New again.

## Add a car for an owner

**People** > **Add a car for an owner**, or **Add another car** on an owner''s page. The owner never has to fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN. The car is looked up at once and shown in one line (Edit if something is wrong); no VIN at hand, add it by its plate with the year, make and model from the lists. Tap the colour, check the class, then the odometer, insurer and whether it is owned, financed or leased. Photos are optional: the listing shows sample photos until real ones are added. Upload the ownership permit, the insurance slip and the lender''s information if you have them.
3. Terms and first invoice: the same fields as Approve. For another car of the same owner they start from that owner''s terms, or their other car''s; change them for this car.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner (only then are you recorded as the one who brought the owner). How the owner signs: by email, or on paper.
5. Press **Add the car and set it up**. The owner gets one email: review the details, correct anything, and sign. An owner with no sign-in gets the link to choose a password in that same email.

Customer service and fleet assistants add cars the same way from their portal; theirs wait in Applications for you, with the terms and invoices they proposed already filled in. On an approved application staff entered, **Send the set-up email again** sends the owner the email with a fresh link.

## Owners

**People** > **Owners**. Every owner, with their cars and where onboarding stands.

1. Each owner shows their application, how many cars, and where onboarding stands.
2. **View as (owner portal)** shows their portal. **Send password link** helps them sign in.
3. Invite an owner on file: fill in Name and Email under Invite an owner, then press **Send invitation**.

![](/guides/img/admin-12-owners-desktop-3a54d505.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/owners; pins: 1 41.0 42.9, 2 37.4 49.3, 3 77.4 82.5")

The owner signs everything at once in their portal (Check and sign: the agreements, schedules and Forms A and B; the official registry forms are printed and signed in ink). The confirmations to tick, then one signature: CarmaCars countersigns at the same moment, under the signing officer''s standing authorization. A car with a second owner on the ownership waits for that owner too: they get their own link by email and sign the same documents.

## Mark a car insured (Insurer confirmed)

A program owner''s car is handed over to a renter only once the insurer confirms in writing that it is on the fleet policy. Requests, offers and payment never wait for it.

1. Each car waiting for the insurer is a line on To do: "Insurer has not confirmed : mark it insured". It says Now when a booking picks the car up soon.
2. When the insurer''s email arrives, press **Mark insured**. The date is today; change it to the date of the insurer''s email if it was earlier. Add its subject as the Reference if you like, and press **Insurer confirmed**.
3. One email for several cars? Press **Mark several insured** on the line " cars wait for the insurer". Every waiting car is ticked: untick any car the insurer did not name, check the date, and confirm them all at once.
4. The same button is on the car: Overview (**Insurer confirmed**) and the Listing tab''s checklist, item "Not on the fleet insurance policy yet".

The car is then on the fleet policy from that date: it can be handed over, its Enrollment Date is that date, its fee terms start, and the owner gets the email "Written confirmation: your car is on the fleet policy". Its paperwork (agreements, registry visit, tracker) stays on its checklist until done. A car already listed and Available stays Available.

## Owners who paid another way, and the terms you agreed

Two lines on To do keep an owner''s money right without opening their page.

1. "Record the first and last month paid by ": their first and last month invoice was voided and nothing paid is recorded. Press **Record what they paid**, type the amount for each car (tax included), or one total for several cars, how and when it was paid and the reference. A draft first and last month invoice is kept or voided, your choice. Each car''s invoice is then marked paid, the owner gets the receipt and the two prepaid months count. Never for a shareholder.
2. "Enter the terms agreed with ": their cars still use the standard grid. Press **Enter the terms**: the Management fee (Revenue Share), the Insurance Fee, the Tracker Fee, the Install Fee and the first and last month are filled in from the grid. Type what you agreed for the owner, and open a car to give it its own. A car whose schedule is signed gets an updated schedule for the owner to sign.
3. Nothing to change? Press **Not needed** or **These are correct**: the line does not come back.

## A shareholder''s own car

On the owner''s page, each car has **Shareholder’s own car**.

1. A shareholder''s own car is split 90/10 (the share in Program settings) and pays no Insurance Fee, Tracker Fee, first and last month or tracker install.
2. Press **Shareholder’s own car**, say why (it is kept in the audit log) and confirm. Press it again to undo. Bookings already made keep their split.
3. A first and last month or a tracker install invoice is refused for such a car, from any screen.

## Cancellation refunds

**Settings** > **Program**: the refund for each cancellation tier.

| When the renter cancels | Refund (default) |
| --- | --- |
| Within 24 hours of booking, 48 hours or more before the start | 95% |
| 48 hours or more before the start | 75% |
| 24 to 48 hours before the start | 50% |
| Under 24 hours, or after the start | 0% |

## An owner''s page

Open an owner from Owners. Three tabs: Overview, Terms and Invoices. **Add another car** and **New invoice** sit under the name.

1. Cars and terms, at the top: each car''s Insurance Fee, Tracker Fee, management fee (Revenue Share), Install Fee and mode, with **Edit** and History (see An owner''s terms, car by car).
2. Upfront invoices: issue the first and last month amount agreed on each car''s terms, for each car whose terms are set.
3. Owner: address, sign-in, agreements, and what is still missing for the registry forms.
4. Statements and payouts for this owner.
5. Forms C and D, with a link to the review queue.
6. Further down: **View as (owner portal)**, **Send password link** and **Send a sign-in link to the owner portal**.

![](/guides/img/admin-13-owner-desktop-819a9f8b.jpg "desktop; size: 410 1030; address: carmacars.ca/admin/owners/9e367055-7780-4451-822a-d79d5b59a309; pins: 1 24.6 4.4, 2 16.1 32.9, 3 31.5 73.2, 4 21.2 98.1")

## An owner''s terms, car by car

The table Cars and terms, at the top of an owner''s page and its Terms tab: each car''s Insurance Fee and Tracker Fee a month, management fee (Revenue Share), Install Fee and Management Mode, and since when they apply.

1. Press **Edit** on a car''s row. The row becomes fields: type the exact amounts (to the cent; the management fee in %). Before the Vehicle Schedule is signed you can also change the Install Fee, the Management Mode and the Onboarding Method.
2. Press **Review**. It lists each value before and after, and what happens to each one. Nothing is saved yet.
3. Not signed yet (or not approved yet): **Save** applies the numbers at once. An unsigned Vehicle Schedule is made again with them, so the owner signs these numbers; a car not approved yet keeps them for the Approve step.
4. Signed: a lower amount is in force from today, or the date you choose under Lower amounts from. No notice period is needed because it only lowers what the owner pays. A lower management fee does this while Settings > Program, Lower management % without owner signature, is on (the default); off, the owner signs an updated Vehicle Schedule first.
5. Signed: a higher Insurance Fee or Tracker Fee needs 30 days'' written notice (Enrollment Agreement 4.8). Choose the date under Higher amounts from (30 days ahead at the earliest) and write the Reason: the owner reads it.
6. Signed: a higher management fee (Revenue Share) needs the same notice and the owner''s signature. The owner is emailed the notice and an updated Vehicle Schedule to sign; it applies from the date once signed, or from the day they sign if that is later. Higher fees in the same change apply from the date by the notice either way.
7. Press **Confirm**. The owner is emailed the written notice, which is also a PDF in their portal and in the car''s History.

History, under each car, lists every period of terms (from, to, the amounts, and why: the Vehicle Schedule, a written notice, lowered) and every change with its notice. A change that has not started yet has Cancel (give the reason): the terms before it run on. An updated schedule waiting for the owner has Record signed on paper (with the date) and Withdraw it. One change at a time: cancel or finish the one waiting before making the next.

The same editor is on the car''s page (Records tab, Owner terms). The owner''s default terms (for cars whose terms are set later) and the first and last month invoice stay on the Terms tab.

> Good to know: Invoices follow the dates: a month whose Insurance Fee or Tracker Fee changes part way is billed per day at each rate. The Revenue Share of a rental is the one in force on the day it is booked.

## Paid and signed

**People** > **Paid and signed**. What each owner still has to pay or sign, and how each item was done.

1. Each owner shows how many items are open and how many are done. Owners with nothing left are hidden; press Show every owner to see them.
2. Open **Checklist and quick actions**. Each line says Signed in the portal, Signed on paper, Paid by e-Transfer, Not signed, and so on.
3. Paid by e-Transfer, cheque, cash or bank transfer? Press **Record payment**. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance, or type less for a partial payment. Add a photo of the cheque or a screenshot if you have one.
4. Signed on paper? Press **Record paper signature**. Choose the Document, check Signed by and Date signed, add the witnesses where the form needs them, and upload the scan of every signed page.
5. The same checklist sits at the top of each owner''s page.
6. You rarely need to come here: an upfront or overdue owner invoice is a line on To do with **Record payment**, and an owner whose documents were sent two days ago or more and are not signed is a line with **Record paper signature**. Both pop-ups are the same forms, filled in.

A recorded payment marks the invoice paid (or partly paid), stops the automatic debit for that amount, sends the owner a receipt, and shows "Paid by e-Transfer on " in their portal. A paper signature counts as signed everywhere: the checklist, onboarding and the owner portal. The scan is kept privately with the owner''s documents.

> Watch out: Recorded the wrong thing, or a cheque bounced? Press **Void** beside it and give the reason. The invoice owes that amount again and the owner is told; a voided signature makes the item open again. Only an Admin can void.

## Forms C and D

**People** > **Owner forms**. Form C is signed on screen in the owner portal, with the witness on the same screen. Form D (and Form C on paper, if the owner prefers) is printed, signed in front of witnesses, and sent as a photo of each page.

1. Each row shows the owner, the form, the witnesses and when it was uploaded.
2. Press Open to read the photo or scan. Check each marked spot is signed or initialled.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/admin-22-owner-forms-desktop-c20ad300.jpg "desktop; size: 1440 470; address: carmacars.ca/admin/owner-forms; pins: 1 29.2 52.3, 2 57.6 52.3, 3 76.7 52.3")
', 'Owners and onboarding', 'Applications, the terms and first invoice, adding a car for an owner, an owner''s terms and invoices, paid and signed, and Forms C and D.',
  'Owners apply on the site with List your car. Every application waits for you in one place, Applications: approve it, ask the owner for something, or decline it. Approved owners sign and pay in their portal.

## Applications

**People** > **Applications**. Every owner application, newest first.

1. The chips filter by status: New, Waiting on owner, Approved, Declined, or All. New applications also show on To do.
2. Each row shows the application number, the owner, the car, how many of the four checks are done, and when they applied.
3. Open an application to decide.

![](/guides/img/admin-33-applications-desktop-152f9e34.jpg "desktop; size: 1440 640; address: carmacars.ca/admin/applications; pins: 1 36.8 39.7, 2 48.6 53.1, 3 19.8 53.1")

## Decide on an application

One page holds everything: the owner, the car, the uploads, the four checks and the notes.

1. Check the driver''s licence, the ownership, the insurance and the lender or lessor. Mark each one Checked, fine, Problem or Not needed.
2. Press **Approve**. The step "Terms and first invoice" opens for each car, filled in with the owner''s negotiated terms (or the standard grid): Insurance Fee, Tracker Fee, management fee (Revenue Share), Install Fee and the first and last month amount (2 x the Insurance Fee unless you type an exact amount). Change any of them to the cent; with several cars, **Use these terms for every car** copies the first car''s numbers to the others.
3. Choose the invoices: First and last month, Registration fee (any exact amount), Tracker install (only once trackers are available) and Another invoice. For each one choose Send now, Save as draft or Already paid. Already paid asks how (e-Transfer, cash, cheque, bank transfer or other), the date and the reference: it is recorded like Record payment and the owner gets the receipt, not an invoice.
4. Press **Approve** at the bottom of the step. Nothing is set or sent before that. The owner becomes active, the documents open for one signature in their portal, only the invoices you chose are made, and the owner gets one email.
5. Missing something? Press **Ask for something**, tick what you need (for example the ownership permit or the insurance slip), add a message if you like, and press **Send to the owner**. The owner gets an email and a task in their portal; the application shows Waiting on owner until they answer.
6. Not a fit? Press **Decline**, write the Reason the owner reads, and press **Decline the application**. The owner is emailed for each car.

![](/guides/img/admin-34-application-desktop-98b64f92.jpg "desktop; size: 1440 812; address: carmacars.ca/admin/applications/166e487a-11a1-4433-b1ca-8c2bc14bf5ca; pins: 1 72.9 67.1, 2 73.9 42.9, 3 84.7 42.9, 4 72.9 49.6")

The application has an Invoices tab: every invoice of its cars, drafts and voids included. An application staff entered for the owner says "Entered by staff" and who; approving it sends the owner the set-up email (review the details and sign) instead of the approval email.

> Tip: Notes on the page are for staff only: **Add note** keeps a line on the record. When the owner answers a request, their answer is in the notes and the application is New again.

## Add a car for an owner

**People** > **Add a car for an owner**, or **Add another car** on an owner''s page. The owner never has to fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN. The car is looked up at once and shown in one line (Edit if something is wrong); no VIN at hand, add it by its plate with the year, make and model from the lists. Tap the colour, check the class, then the odometer, insurer and whether it is owned, financed or leased. Photos are optional: the listing shows sample photos until real ones are added. Upload the ownership permit, the insurance slip and the lender''s information if you have them.
3. Terms and first invoice: the same fields as Approve. For another car of the same owner they start from that owner''s terms, or their other car''s; change them for this car.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner (only then are you recorded as the one who brought the owner). How the owner signs: by email, or on paper.
5. Press **Add the car and set it up**. The owner gets one email: review the details, correct anything, and sign. An owner with no sign-in gets the link to choose a password in that same email.

Customer service and fleet assistants add cars the same way from their portal; theirs wait in Applications for you, with the terms and invoices they proposed already filled in. On an approved application staff entered, **Send the set-up email again** sends the owner the email with a fresh link.

## Owners

**People** > **Owners**. Every owner, with their cars and where onboarding stands.

1. Each owner shows their application, how many cars, and where onboarding stands.
2. **View as (owner portal)** shows their portal. **Send password link** helps them sign in.
3. Invite an owner on file: fill in Name and Email under Invite an owner, then press **Send invitation**.

![](/guides/img/admin-12-owners-desktop-3a54d505.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/owners; pins: 1 41.0 42.9, 2 37.4 49.3, 3 77.4 82.5")

The owner signs everything at once in their portal (Check and sign: the agreements, schedules and Forms A and B; the official registry forms are printed and signed in ink). The confirmations to tick, then one signature: CarmaCars countersigns at the same moment, under the signing officer''s standing authorization. A car with a second owner on the ownership waits for that owner too: they get their own link by email and sign the same documents.

## Mark a car insured (Insurer confirmed)

A program owner''s car is handed over to a renter only once the insurer confirms in writing that it is on the fleet policy. Requests, offers and payment never wait for it.

1. Each car waiting for the insurer is a line on To do: "Insurer has not confirmed : mark it insured". It says Now when a booking picks the car up soon.
2. When the insurer''s email arrives, press **Mark insured**. The date is today; change it to the date of the insurer''s email if it was earlier. Add its subject as the Reference if you like, and press **Insurer confirmed**.
3. One email for several cars? Press **Mark several insured** on the line " cars wait for the insurer". Every waiting car is ticked: untick any car the insurer did not name, check the date, and confirm them all at once.
4. The same button is on the car: Overview (**Insurer confirmed**) and the Listing tab''s checklist, item "Not on the fleet insurance policy yet".

The car is then on the fleet policy from that date: it can be handed over, its Enrollment Date is that date, its fee terms start, and the owner gets the email "Written confirmation: your car is on the fleet policy". Its paperwork (agreements, registry visit, tracker) stays on its checklist until done. A car already listed and Available stays Available.

## Owners who paid another way, and the terms you agreed

Two lines on To do keep an owner''s money right without opening their page.

1. "Record the first and last month paid by ": their first and last month invoice was voided and nothing paid is recorded. Press **Record what they paid**, type the amount for each car (tax included), or one total for several cars, how and when it was paid and the reference. A draft first and last month invoice is kept or voided, your choice. Each car''s invoice is then marked paid, the owner gets the receipt and the two prepaid months count. Never for a shareholder.
2. "Enter the terms agreed with ": their cars still use the standard grid. Press **Enter the terms**: the Management fee (Revenue Share), the Insurance Fee, the Tracker Fee, the Install Fee and the first and last month are filled in from the grid. Type what you agreed for the owner, and open a car to give it its own. A car whose schedule is signed gets an updated schedule for the owner to sign.
3. Nothing to change? Press **Not needed** or **These are correct**: the line does not come back.

## A shareholder''s own car

On the owner''s page, each car has **Shareholder’s own car**.

1. A shareholder''s own car is split 90/10 (the share in Program settings) and pays no Insurance Fee, Tracker Fee, first and last month or tracker install.
2. Press **Shareholder’s own car**, say why (it is kept in the audit log) and confirm. Press it again to undo. Bookings already made keep their split.
3. A first and last month or a tracker install invoice is refused for such a car, from any screen.

## Cancellation refunds

**Settings** > **Program**: the refund for each cancellation tier.

| When the renter cancels | Refund (default) |
| --- | --- |
| Within 24 hours of booking, 48 hours or more before the start | 95% |
| 48 hours or more before the start | 75% |
| 24 to 48 hours before the start | 50% |
| Under 24 hours, or after the start | 0% |

## An owner''s page

Open an owner from Owners. Three tabs: Overview, Terms and Invoices. **Add another car** and **New invoice** sit under the name.

1. Cars and terms, at the top: each car''s Insurance Fee, Tracker Fee, management fee (Revenue Share), Install Fee and mode, with **Edit** and History (see An owner''s terms, car by car).
2. Upfront invoices: issue the first and last month amount agreed on each car''s terms, for each car whose terms are set.
3. Owner: address, sign-in, agreements, and what is still missing for the registry forms.
4. Statements and payouts for this owner.
5. Forms C and D, with a link to the review queue.
6. Further down: **View as (owner portal)**, **Send password link** and **Send a sign-in link to the owner portal**.

![](/guides/img/admin-13-owner-desktop-819a9f8b.jpg "desktop; size: 410 1030; address: carmacars.ca/admin/owners/9e367055-7780-4451-822a-d79d5b59a309; pins: 1 24.6 4.4, 2 16.1 32.9, 3 31.5 73.2, 4 21.2 98.1")

## An owner''s terms, car by car

The table Cars and terms, at the top of an owner''s page and its Terms tab: each car''s Insurance Fee and Tracker Fee a month, management fee (Revenue Share), Install Fee and Management Mode, and since when they apply.

1. Press **Edit** on a car''s row. The row becomes fields: type the exact amounts (to the cent; the management fee in %). Before the Vehicle Schedule is signed you can also change the Install Fee, the Management Mode and the Onboarding Method.
2. Press **Review**. It lists each value before and after, and what happens to each one. Nothing is saved yet.
3. Not signed yet (or not approved yet): **Save** applies the numbers at once. An unsigned Vehicle Schedule is made again with them, so the owner signs these numbers; a car not approved yet keeps them for the Approve step.
4. Signed: a lower amount is in force from today, or the date you choose under Lower amounts from. No notice period is needed because it only lowers what the owner pays. A lower management fee does this while Settings > Program, Lower management % without owner signature, is on (the default); off, the owner signs an updated Vehicle Schedule first.
5. Signed: a higher Insurance Fee or Tracker Fee needs 30 days'' written notice (Enrollment Agreement 4.8). Choose the date under Higher amounts from (30 days ahead at the earliest) and write the Reason: the owner reads it.
6. Signed: a higher management fee (Revenue Share) needs the same notice and the owner''s signature. The owner is emailed the notice and an updated Vehicle Schedule to sign; it applies from the date once signed, or from the day they sign if that is later. Higher fees in the same change apply from the date by the notice either way.
7. Press **Confirm**. The owner is emailed the written notice, which is also a PDF in their portal and in the car''s History.

History, under each car, lists every period of terms (from, to, the amounts, and why: the Vehicle Schedule, a written notice, lowered) and every change with its notice. A change that has not started yet has Cancel (give the reason): the terms before it run on. An updated schedule waiting for the owner has Record signed on paper (with the date) and Withdraw it. One change at a time: cancel or finish the one waiting before making the next.

The same editor is on the car''s page (Records tab, Owner terms). The owner''s default terms (for cars whose terms are set later) and the first and last month invoice stay on the Terms tab.

> Good to know: Invoices follow the dates: a month whose Insurance Fee or Tracker Fee changes part way is billed per day at each rate. The Revenue Share of a rental is the one in force on the day it is booked.

## Change a signed car''s Management Mode

Managed, Self-Managed or Turo-Only, from a date, for a car whose Vehicle Schedule is signed. An Admin only.

1. Open the owner''s Cars and terms table (or the car''s page) and press **Change mode** on the car''s row.
2. Choose the **New Management Mode** and its Onboarding Method (the options that fit how the car is held), the date under **From**, and write the Reason: the owner reads it. Tick **The owner asked for this** only when it is their own request.
3. Press **Review**: it lists each value before and after (a Self-Managed car has no management fee; a Turo-Only car has no Fees and leaves the fleet insurance policy) and says whether the owner has to sign. Nothing is saved yet.
4. The owner asked and no amount goes up: no signature and no notice period. From today (or the date you chose) the car has the new mode, an updated Vehicle Schedule is issued with CarmaCars'' signature and the owner is emailed the notice.
5. Anything else (CarmaCars'' own decision, or a higher fee): the owner is emailed the notice and an updated Vehicle Schedule to sign, the date is at least 30 days away and the car stays as it is until it is signed. In History, **Record signed on paper** or **Withdraw it**.
6. A change dated ahead applies by itself on its date: the schedule is issued and the car moves. **Cancel** in History (give the reason) stops it and emails the owner that their terms stay as they are. The same email goes when a notice of a higher fee is cancelled.

> Good to know: A shareholder-owned car has fixed terms. A car whose schedule is not signed yet changes its mode in the terms editor, where it applies at once.

## Paid and signed

**People** > **Paid and signed**. What each owner still has to pay or sign, and how each item was done.

1. Each owner shows how many items are open and how many are done. Owners with nothing left are hidden; press Show every owner to see them.
2. Open **Checklist and quick actions**. Each line says Signed in the portal, Signed on paper, Paid by e-Transfer, Not signed, and so on.
3. Paid by e-Transfer, cheque, cash or bank transfer? Press **Record payment**. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance, or type less for a partial payment. Add a photo of the cheque or a screenshot if you have one.
4. Signed on paper? Press **Record paper signature**. Choose the Document, check Signed by and Date signed, add the witnesses where the form needs them, and upload the scan of every signed page.
5. The same checklist sits at the top of each owner''s page.
6. You rarely need to come here: an upfront or overdue owner invoice is a line on To do with **Record payment**, and an owner whose documents were sent two days ago or more and are not signed is a line with **Record paper signature**. Both pop-ups are the same forms, filled in.

A recorded payment marks the invoice paid (or partly paid), stops the automatic debit for that amount, sends the owner a receipt, and shows "Paid by e-Transfer on " in their portal. A paper signature counts as signed everywhere: the checklist, onboarding and the owner portal. The scan is kept privately with the owner''s documents.

> Watch out: Recorded the wrong thing, or a cheque bounced? Press **Void** beside it and give the reason. The invoice owes that amount again and the owner is told; a voided signature makes the item open again. Only an Admin can void.

## Forms C and D

**People** > **Owner forms**. Form C is signed on screen in the owner portal, with the witness on the same screen. Form D (and Form C on paper, if the owner prefers) is printed, signed in front of witnesses, and sent as a photo of each page.

1. Each row shows the owner, the form, the witnesses and when it was uploaded.
2. Press Open to read the photo or scan. Check each marked spot is signed or initialled.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/admin-22-owner-forms-desktop-c20ad300.jpg "desktop; size: 1440 470; address: carmacars.ca/admin/owner-forms; pins: 1 29.2 52.3, 2 57.6 52.3, 3 76.7 52.3")
',
  '<p class="gd-p">Owners apply on the site with List your car. Every application waits for you in one place, Applications: approve it, ask the owner for something, or decline it. Approved owners sign and pay in their portal.</p><section class="gd-task" id="owners-and-onboarding-applications" data-gd-task><h2 class="gd-h2">Applications</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Applications</b>. Every owner application, newest first.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The chips filter by status: New, Waiting on owner, Approved, Declined, or All. New applications also show on To do.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each row shows the application number, the owner, the car, how many of the four checks are done, and when they applied.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open an application to decide.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/applications</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/admin-33-applications-desktop-152f9e34.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:36.8%;top:39.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:48.6%;top:53.1%" aria-hidden="true">2</span><span class="gd-pin" style="left:19.8%;top:53.1%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="owners-and-onboarding-decide-on-an-application" data-gd-task><h2 class="gd-h2">Decide on an application</h2><p class="gd-p">One page holds everything: the owner, the car, the uploads, the four checks and the notes.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Check the driver&#39;s licence, the ownership, the insurance and the lender or lessor. Mark each one Checked, fine, Problem or Not needed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Approve</b>. The step &quot;Terms and first invoice&quot; opens for each car, filled in with the owner&#39;s negotiated terms (or the standard grid): Insurance Fee, Tracker Fee, management fee (Revenue Share), Install Fee and the first and last month amount (2 x the Insurance Fee unless you type an exact amount). Change any of them to the cent; with several cars, <b class="gd-ui">Use these terms for every car</b> copies the first car&#39;s numbers to the others.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Choose the invoices: First and last month, Registration fee (any exact amount), Tracker install (only once trackers are available) and Another invoice. For each one choose Send now, Save as draft or Already paid. Already paid asks how (e-Transfer, cash, cheque, bank transfer or other), the date and the reference: it is recorded like Record payment and the owner gets the receipt, not an invoice.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Approve</b> at the bottom of the step. Nothing is set or sent before that. The owner becomes active, the documents open for one signature in their portal, only the invoices you chose are made, and the owner gets one email.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Missing something? Press <b class="gd-ui">Ask for something</b>, tick what you need (for example the ownership permit or the insurance slip), add a message if you like, and press <b class="gd-ui">Send to the owner</b>. The owner gets an email and a task in their portal; the application shows Waiting on owner until they answer.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Not a fit? Press <b class="gd-ui">Decline</b>, write the Reason the owner reads, and press <b class="gd-ui">Decline the application</b>. The owner is emailed for each car.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/applications/166e487a-11a1-4433-b1ca-8c2bc14bf5ca</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/812"><img src="/guides/img/admin-34-application-desktop-98b64f92.jpg" alt="" loading="lazy" decoding="async" width="1440" height="812"><span class="gd-pin" style="left:72.9%;top:67.1%" aria-hidden="true">1</span><span class="gd-pin" style="left:73.9%;top:42.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:84.7%;top:42.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:72.9%;top:49.6%" aria-hidden="true">4</span></div></div></figure></div><p class="gd-p">The application has an Invoices tab: every invoice of its cars, drafts and voids included. An application staff entered for the owner says &quot;Entered by staff&quot; and who; approving it sends the owner the set-up email (review the details and sign) instead of the approval email.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Notes on the page are for staff only: <b class="gd-ui">Add note</b> keeps a line on the record. When the owner answers a request, their answer is in the notes and the application is New again.</div></aside></section><section class="gd-task" id="owners-and-onboarding-add-a-car-for-an-owner" data-gd-task><h2 class="gd-h2">Add a car for an owner</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Add a car for an owner</b>, or <b class="gd-ui">Add another car</b> on an owner&#39;s page. The owner never has to fill in the application.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car: type the VIN. The car is looked up at once and shown in one line (Edit if something is wrong); no VIN at hand, add it by its plate with the year, make and model from the lists. Tap the colour, check the class, then the odometer, insurer and whether it is owned, financed or leased. Photos are optional: the listing shows sample photos until real ones are added. Upload the ownership permit, the insurance slip and the lender&#39;s information if you have them.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Terms and first invoice: the same fields as Approve. For another car of the same owner they start from that owner&#39;s terms, or their other car&#39;s; change them for this car.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Who sourced the owner: Entered for CarmaCars, or I sourced this owner (only then are you recorded as the one who brought the owner). How the owner signs: by email, or on paper.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Add the car and set it up</b>. The owner gets one email: review the details, correct anything, and sign. An owner with no sign-in gets the link to choose a password in that same email.</div></li></ol></div><p class="gd-p">Customer service and fleet assistants add cars the same way from their portal; theirs wait in Applications for you, with the terms and invoices they proposed already filled in. On an approved application staff entered, <b class="gd-ui">Send the set-up email again</b> sends the owner the email with a fresh link.</p></section><section class="gd-task" id="owners-and-onboarding-owners" data-gd-task><h2 class="gd-h2">Owners</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Owners</b>. Every owner, with their cars and where onboarding stands.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each owner shows their application, how many cars, and where onboarding stands.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">View as (owner portal)</b> shows their portal. <b class="gd-ui">Send password link</b> helps them sign in.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Invite an owner on file: fill in Name and Email under Invite an owner, then press <b class="gd-ui">Send invitation</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/owners</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/560"><img src="/guides/img/admin-12-owners-desktop-3a54d505.jpg" alt="" loading="lazy" decoding="async" width="1440" height="560"><span class="gd-pin" style="left:41%;top:42.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:37.4%;top:49.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:82.5%" aria-hidden="true">3</span></div></div></figure></div><p class="gd-p">The owner signs everything at once in their portal (Check and sign: the agreements, schedules and Forms A and B; the official registry forms are printed and signed in ink). The confirmations to tick, then one signature: CarmaCars countersigns at the same moment, under the signing officer&#39;s standing authorization. A car with a second owner on the ownership waits for that owner too: they get their own link by email and sign the same documents.</p></section><section class="gd-task" id="owners-and-onboarding-mark-a-car-insured-insurer-confirmed" data-gd-task><h2 class="gd-h2">Mark a car insured (Insurer confirmed)</h2><p class="gd-p">A program owner&#39;s car is handed over to a renter only once the insurer confirms in writing that it is on the fleet policy. Requests, offers and payment never wait for it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each car waiting for the insurer is a line on To do: &quot;Insurer has not confirmed : mark it insured&quot;. It says Now when a booking picks the car up soon.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">When the insurer&#39;s email arrives, press <b class="gd-ui">Mark insured</b>. The date is today; change it to the date of the insurer&#39;s email if it was earlier. Add its subject as the Reference if you like, and press <b class="gd-ui">Insurer confirmed</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">One email for several cars? Press <b class="gd-ui">Mark several insured</b> on the line &quot; cars wait for the insurer&quot;. Every waiting car is ticked: untick any car the insurer did not name, check the date, and confirm them all at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The same button is on the car: Overview (<b class="gd-ui">Insurer confirmed</b>) and the Listing tab&#39;s checklist, item &quot;Not on the fleet insurance policy yet&quot;.</div></li></ol></div><p class="gd-p">The car is then on the fleet policy from that date: it can be handed over, its Enrollment Date is that date, its fee terms start, and the owner gets the email &quot;Written confirmation: your car is on the fleet policy&quot;. Its paperwork (agreements, registry visit, tracker) stays on its checklist until done. A car already listed and Available stays Available.</p></section><section class="gd-task" id="owners-and-onboarding-owners-who-paid-another-way-and-the-terms-you-agreed" data-gd-task><h2 class="gd-h2">Owners who paid another way, and the terms you agreed</h2><p class="gd-p">Two lines on To do keep an owner&#39;s money right without opening their page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">&quot;Record the first and last month paid by &quot;: their first and last month invoice was voided and nothing paid is recorded. Press <b class="gd-ui">Record what they paid</b>, type the amount for each car (tax included), or one total for several cars, how and when it was paid and the reference. A draft first and last month invoice is kept or voided, your choice. Each car&#39;s invoice is then marked paid, the owner gets the receipt and the two prepaid months count. Never for a shareholder.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">&quot;Enter the terms agreed with &quot;: their cars still use the standard grid. Press <b class="gd-ui">Enter the terms</b>: the Management fee (Revenue Share), the Insurance Fee, the Tracker Fee, the Install Fee and the first and last month are filled in from the grid. Type what you agreed for the owner, and open a car to give it its own. A car whose schedule is signed gets an updated schedule for the owner to sign.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Nothing to change? Press <b class="gd-ui">Not needed</b> or <b class="gd-ui">These are correct</b>: the line does not come back.</div></li></ol></div></section><section class="gd-task" id="owners-and-onboarding-a-shareholder-s-own-car" data-gd-task><h2 class="gd-h2">A shareholder&#39;s own car</h2><p class="gd-p">On the owner&#39;s page, each car has <b class="gd-ui">Shareholder’s own car</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A shareholder&#39;s own car is split 90/10 (the share in Program settings) and pays no Insurance Fee, Tracker Fee, first and last month or tracker install.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Shareholder’s own car</b>, say why (it is kept in the audit log) and confirm. Press it again to undo. Bookings already made keep their split.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A first and last month or a tracker install invoice is refused for such a car, from any screen.</div></li></ol></div></section><section class="gd-task" id="owners-and-onboarding-cancellation-refunds" data-gd-task><h2 class="gd-h2">Cancellation refunds</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>: the refund for each cancellation tier.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">When the renter cancels</th><th scope="col">Refund (default)</th></tr></thead><tbody><tr><td>Within 24 hours of booking, 48 hours or more before the start</td><td>95%</td></tr><tr><td>48 hours or more before the start</td><td>75%</td></tr><tr><td>24 to 48 hours before the start</td><td>50%</td></tr><tr><td>Under 24 hours, or after the start</td><td>0%</td></tr></tbody></table></div></section><section class="gd-task" id="owners-and-onboarding-an-owner-s-page" data-gd-task><h2 class="gd-h2">An owner&#39;s page</h2><p class="gd-p">Open an owner from Owners. Three tabs: Overview, Terms and Invoices. <b class="gd-ui">Add another car</b> and <b class="gd-ui">New invoice</b> sit under the name.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Cars and terms, at the top: each car&#39;s Insurance Fee, Tracker Fee, management fee (Revenue Share), Install Fee and mode, with <b class="gd-ui">Edit</b> and History (see An owner&#39;s terms, car by car).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Upfront invoices: issue the first and last month amount agreed on each car&#39;s terms, for each car whose terms are set.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Owner: address, sign-in, agreements, and what is still missing for the registry forms.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Statements and payouts for this owner.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Forms C and D, with a link to the review queue.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Further down: <b class="gd-ui">View as (owner portal)</b>, <b class="gd-ui">Send password link</b> and <b class="gd-ui">Send a sign-in link to the owner portal</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/owners/9e367055-7780-4451-822a-d79d5b59a309</span></div><div class="gd-imgwrap" style="aspect-ratio:410/1030"><img src="/guides/img/admin-13-owner-desktop-819a9f8b.jpg" alt="" loading="lazy" decoding="async" width="410" height="1030"><span class="gd-pin" style="left:24.6%;top:4.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:16.1%;top:32.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:31.5%;top:73.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:21.2%;top:98.1%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="owners-and-onboarding-an-owner-s-terms-car-by-car" data-gd-task><h2 class="gd-h2">An owner&#39;s terms, car by car</h2><p class="gd-p">The table Cars and terms, at the top of an owner&#39;s page and its Terms tab: each car&#39;s Insurance Fee and Tracker Fee a month, management fee (Revenue Share), Install Fee and Management Mode, and since when they apply.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Edit</b> on a car&#39;s row. The row becomes fields: type the exact amounts (to the cent; the management fee in %). Before the Vehicle Schedule is signed you can also change the Install Fee, the Management Mode and the Onboarding Method.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Review</b>. It lists each value before and after, and what happens to each one. Nothing is saved yet.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Not signed yet (or not approved yet): <b class="gd-ui">Save</b> applies the numbers at once. An unsigned Vehicle Schedule is made again with them, so the owner signs these numbers; a car not approved yet keeps them for the Approve step.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Signed: a lower amount is in force from today, or the date you choose under Lower amounts from. No notice period is needed because it only lowers what the owner pays. A lower management fee does this while Settings &gt; Program, Lower management % without owner signature, is on (the default); off, the owner signs an updated Vehicle Schedule first.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Signed: a higher Insurance Fee or Tracker Fee needs 30 days&#39; written notice (Enrollment Agreement 4.8). Choose the date under Higher amounts from (30 days ahead at the earliest) and write the Reason: the owner reads it.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Signed: a higher management fee (Revenue Share) needs the same notice and the owner&#39;s signature. The owner is emailed the notice and an updated Vehicle Schedule to sign; it applies from the date once signed, or from the day they sign if that is later. Higher fees in the same change apply from the date by the notice either way.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Press <b class="gd-ui">Confirm</b>. The owner is emailed the written notice, which is also a PDF in their portal and in the car&#39;s History.</div></li></ol></div><p class="gd-p">History, under each car, lists every period of terms (from, to, the amounts, and why: the Vehicle Schedule, a written notice, lowered) and every change with its notice. A change that has not started yet has Cancel (give the reason): the terms before it run on. An updated schedule waiting for the owner has Record signed on paper (with the date) and Withdraw it. One change at a time: cancel or finish the one waiting before making the next.</p><p class="gd-p">The same editor is on the car&#39;s page (Records tab, Owner terms). The owner&#39;s default terms (for cars whose terms are set later) and the first and last month invoice stay on the Terms tab.</p><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Invoices follow the dates: a month whose Insurance Fee or Tracker Fee changes part way is billed per day at each rate. The Revenue Share of a rental is the one in force on the day it is booked.</div></aside></section><section class="gd-task" id="owners-and-onboarding-change-a-signed-car-s-management-mode" data-gd-task><h2 class="gd-h2">Change a signed car&#39;s Management Mode</h2><p class="gd-p">Managed, Self-Managed or Turo-Only, from a date, for a car whose Vehicle Schedule is signed. An Admin only.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the owner&#39;s Cars and terms table (or the car&#39;s page) and press <b class="gd-ui">Change mode</b> on the car&#39;s row.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the <b class="gd-ui">New Management Mode</b> and its Onboarding Method (the options that fit how the car is held), the date under <b class="gd-ui">From</b>, and write the Reason: the owner reads it. Tick <b class="gd-ui">The owner asked for this</b> only when it is their own request.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Review</b>: it lists each value before and after (a Self-Managed car has no management fee; a Turo-Only car has no Fees and leaves the fleet insurance policy) and says whether the owner has to sign. Nothing is saved yet.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The owner asked and no amount goes up: no signature and no notice period. From today (or the date you chose) the car has the new mode, an updated Vehicle Schedule is issued with CarmaCars&#39; signature and the owner is emailed the notice.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Anything else (CarmaCars&#39; own decision, or a higher fee): the owner is emailed the notice and an updated Vehicle Schedule to sign, the date is at least 30 days away and the car stays as it is until it is signed. In History, <b class="gd-ui">Record signed on paper</b> or <b class="gd-ui">Withdraw it</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A change dated ahead applies by itself on its date: the schedule is issued and the car moves. <b class="gd-ui">Cancel</b> in History (give the reason) stops it and emails the owner that their terms stay as they are. The same email goes when a notice of a higher fee is cancelled.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A shareholder-owned car has fixed terms. A car whose schedule is not signed yet changes its mode in the terms editor, where it applies at once.</div></aside></section><section class="gd-task" id="owners-and-onboarding-paid-and-signed" data-gd-task><h2 class="gd-h2">Paid and signed</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Paid and signed</b>. What each owner still has to pay or sign, and how each item was done.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each owner shows how many items are open and how many are done. Owners with nothing left are hidden; press Show every owner to see them.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open <b class="gd-ui">Checklist and quick actions</b>. Each line says Signed in the portal, Signed on paper, Paid by e-Transfer, Not signed, and so on.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Paid by e-Transfer, cheque, cash or bank transfer? Press <b class="gd-ui">Record payment</b>. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance, or type less for a partial payment. Add a photo of the cheque or a screenshot if you have one.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Signed on paper? Press <b class="gd-ui">Record paper signature</b>. Choose the Document, check Signed by and Date signed, add the witnesses where the form needs them, and upload the scan of every signed page.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The same checklist sits at the top of each owner&#39;s page.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">You rarely need to come here: an upfront or overdue owner invoice is a line on To do with <b class="gd-ui">Record payment</b>, and an owner whose documents were sent two days ago or more and are not signed is a line with <b class="gd-ui">Record paper signature</b>. Both pop-ups are the same forms, filled in.</div></li></ol></div><p class="gd-p">A recorded payment marks the invoice paid (or partly paid), stops the automatic debit for that amount, sends the owner a receipt, and shows &quot;Paid by e-Transfer on &quot; in their portal. A paper signature counts as signed everywhere: the checklist, onboarding and the owner portal. The scan is kept privately with the owner&#39;s documents.</p><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Recorded the wrong thing, or a cheque bounced? Press <b class="gd-ui">Void</b> beside it and give the reason. The invoice owes that amount again and the owner is told; a voided signature makes the item open again. Only an Admin can void.</div></aside></section><section class="gd-task" id="owners-and-onboarding-forms-c-and-d" data-gd-task><h2 class="gd-h2">Forms C and D</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Owner forms</b>. Form C is signed on screen in the owner portal, with the witness on the same screen. Form D (and Form C on paper, if the owner prefers) is printed, signed in front of witnesses, and sent as a photo of each page.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each row shows the owner, the form, the witnesses and when it was uploaded.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press Open to read the photo or scan. Check each marked spot is signed or initialled.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Approve</b>, or <b class="gd-ui">Send back</b> with What to fix (the owner reads this).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/owner-forms</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/470"><img src="/guides/img/admin-22-owner-forms-desktop-c20ad300.jpg" alt="" loading="lazy" decoding="async" width="1440" height="470"><span class="gd-pin" style="left:29.2%;top:52.3%" aria-hidden="true">1</span><span class="gd-pin" style="left:57.6%;top:52.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:76.7%;top:52.3%" aria-hidden="true">3</span></div></div></figure></div></section>');
select app.guide_release_section('admin', 'owner-money', 'chapter', 'owners-and-onboarding', 'Owner fee invoices are issued on the notice day and debited on the 15th. Invoices of any amount are made by hand, as drafts first. Statements are built, approved and issued each month, and payouts follow.

## Owner invoices

**Money** > **Owner invoices**. Every owner invoice, drafts and voids included. The same list is on each owner''s and each application''s Invoices tab.

1. Filter by Drafts, Open, Partly paid, Paid, Failed, In arrears or Void, or search by invoice number or owner. Open an invoice to see everything about it.
2. **New invoice** makes an invoice of any amount for an owner''s car, for example a registration fee of $123.45.
3. The monthly run and tracker invoices: **Run the monthly invoices** issues the invoices for the 15th by hand, for a missed month (never twice); **Issue all tracker invoices** bills the Tracker Install for each car waiting for its tracker.

![](/guides/img/admin-14-owner-invoices-desktop-dc4ed1f1.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/invoices; pins: 1 83.3 22.4, 2 41.7 35.7, 3 29.0 43.4")

## Make, edit and issue an invoice

A new invoice is a draft: the owner sees nothing and it is never debited until you issue it.

1. Choose the car, a title (for example Registration fee) and, if you like, the due date (empty: 7 days after it is issued). Each line: the description, the quantity, the unit amount to the cent, HST on or off, and a note. **Add a line** for more.
2. **Save as draft** to come back to it, or **Save and issue** to send it now. On a draft''s page, **Issue and email** sends it.
3. Paid another way? Press **Record payment** on the invoice. The page lists the payments with their receipts, the automatic debits, the emails sent and the history.
4. **Resend email** sends the invoice again. **PDF** opens it as a PDF.

## Correct an issued invoice

An issued invoice is never edited. You void it and issue a corrected one.

1. Press **Void**, write the reason (the owner reads it), keep Make a corrected invoice from it ticked, and press **Void the invoice**. Its scheduled debit is cancelled and the owner is told.
2. The corrected invoice opens as a draft with the same lines. Fix the amounts and press **Save and issue**.
3. Already paid? Void the payment first, or press **Credit note** for the amount to give back: it gets its own number and the owner sees it.

Invoices issued before October 20, 2026 at the old default (for example $904.00, or $1,017.00 when the Insurance Fee was $450.00) are not changed by themselves. Where an owner agreed another amount, void them and reissue at the agreed amount.

## The automatic debit

The debit runs by itself. Your job is to watch for returned debits and owners without a mandate.

:::flow
Notice day | Invoices issued, one notice per owner, 10 days before
Debit day | The 15th from 6:00: one debit per invoice
Cleared | The invoice is paid
Returned, insufficient funds | The $50.00 Late Fee is added once; the same amount is tried again within 30 days
Returned for another reason | No retry and no Late Fee: the debit pauses and you get a task
:::

1. The tiles show the next debit day and notice day, scheduled, processing, cleared and returned debits.
2. How it runs explains the policy in words, read from Program settings.
3. Scheduled and processing lists each debit. **Pause** holds one (a reason is needed).
4. Owners lists each mandate. Use **Pause**, **Resume** or **Send a notice now**.

![](/guides/img/admin-15-owner-debits-desktop-f65f061a.jpg "desktop; size: 1440 920; address: carmacars.ca/admin/debits; pins: 1 21.8 21.7, 2 21.5 35.5, 3 91.5 75.4, 4 84.7 94.7")

5. Results: each debit, cleared or returned, with the bank''s reason.
6. Run log: each notice and debit run, with its counts.
7. Notices sent: who was told what, for which debit day.

![](/guides/img/admin-15-owner-debits-desktop-8d4682bc.jpg "desktop; size: 1230 520; address: carmacars.ca/admin/debits; pins: 5 11.0 14.4, 6 10.2 52.3, 7 15.4 89.8")

Insufficient funds: the $50.00 Late Fee is added to that invoice once and collected with the owner''s next debit, and the original amount is tried again within 30 days, as section 4.4 of the Enrollment Agreement sets out. The retry is never more than the original amount. Returned again: the invoice is in arrears and you get a task.

> Watch out: Returned for any other reason (account closed, payment stopped, no authorization): there is no retry and no Late Fee. The owner''s debit pauses, the owner gets an email asking them to fix the account or pay another way, and you get a task. A debit is never more than its notice said. An owner with no mandate gets an email on the notice day and you get a task; nothing is debited for them.

## Owner statements

**Money** > **Owner statements**

1. Press **Build all for a month** (or **Build one**).
2. Open each draft. Check it, **Rebuild** after a correction, **Preview PDF**, then **Approve**.
3. Press **Issue to the owner**. **Reissue** sends a corrected copy; **CSV** exports it.

![](/guides/img/admin-16-statements-desktop-43a313ea.jpg "desktop; size: 1440 400; address: carmacars.ca/admin/statements; pins: 1 79.9 27.3")

![An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts.](/guides/img/admin-17-statement-desktop-106ee57f.jpg "desktop; size: 1440 520; address: carmacars.ca/admin/statements/f27936a8-9bfb-4280-81ae-c67ec47febe1; pins: 3 86.0 22.7")

## Staff commissions

**Money** > **Staff commissions**. Nothing is paid automatically.

:::flow
Not earned yet | The rental is ahead, or not paid in full
Pending approval | Completed and paid in full; a Sales month once it has ended
Approved | You approved it; the staff member is told
Paid | You recorded the payment; the staff member is told
Reversed | Cancelled, refunded or charged back; after payment it comes off the next payment
:::

1. By person shows each staff member''s month (Sales: rental days of 100 and the tier), what is not earned yet, pending approval, approved and paid.
2. Press **Approve** on a person (everything that may be approved now) or on one commission.
3. Press **Record a payment**: choose how it was paid (e-Transfer, bank transfer, Wise, cash, the monthly pay statement or another way), the reference and the date.
4. **Prices to review** lists prices typed by hand; **Sourcing claims** lists staff who say they sourced a website request; **Payments made** lists each payment.

|  | Commission |
| --- | --- |
| Sales | By rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all that month''s rentals |
| Customer service, finance, fleet, field staff | 10% (also the field referral fee) |
| Base | The rental charge before tax, after discounts, with late extra days; never delivery, kilometres, add-ons or anything else bought. Only a refund of the rental charge comes off |
| On the owner statement | An owner''s car: deducted with the kickbacks before Owner Revenue, its own line on the statement. A partner''s car: from CarmaCars'' commission. A CarmaCars-owned car: a CarmaCars expense |

> Tip: A commission that changes after an owner statement was built (a refund, or the month''s Sales tier) goes on the owner''s next statement as an adjustment line.

## Company statements

CarmaCars'' own monthly statement, in twelve sections.

1. Choose the month. The tiles show revenue, fees, refunds, expenses and the company net.
2. Switch between Total, Per owner and Per vehicle.
3. Download **PDF**, **PDF by owner** or **PDF by vehicle**, or press **Email me the PDFs**.
4. **Finalize** freezes the month. **Rebuild** works until then.

![](/guides/img/admin-18-company-statements-desktop-8e2738ed.jpg "desktop; size: 1440 760; address: carmacars.ca/admin/reports; pins: 1 20.8 28.0, 2 19.4 59.3, 3 77.1 15.5, 4 46.9 15.5")
', 'Owner money', 'Owner invoices (drafts, void and reissue, credit notes), the automatic debit, statements, payouts and the company statement.',
  'Owner fee invoices are issued on the notice day and debited on the 15th. Invoices of any amount are made by hand, as drafts first. Statements are built, approved and issued each month, and payouts follow.

## Owner invoices

**Money** > **Owner invoices**. Every owner invoice, drafts and voids included. The same list is on each owner''s and each application''s Invoices tab.

1. Filter by Drafts, Open, Partly paid, Paid, Failed, In arrears or Void, or search by invoice number or owner. Open an invoice to see everything about it.
2. **New invoice** makes an invoice of any amount for an owner''s car, for example a registration fee of $123.45.
3. The monthly run and tracker invoices: **Run the monthly invoices** issues the invoices for the 15th by hand, for a missed month (never twice); **Issue all tracker invoices** bills the Tracker Install for each car waiting for its tracker.

![](/guides/img/admin-14-owner-invoices-desktop-dc4ed1f1.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/invoices; pins: 1 83.3 22.4, 2 41.7 35.7, 3 29.0 43.4")

## Make, edit and issue an invoice

A new invoice is a draft: the owner sees nothing and it is never debited until you issue it.

1. Choose the car, a title (for example Registration fee) and, if you like, the due date (empty: 7 days after it is issued). Each line: the description, the quantity, the unit amount to the cent, HST on or off, and a note. **Add a line** for more.
2. **Save as draft** to come back to it, or **Save and issue** to send it now. On a draft''s page, **Issue and email** sends it.
3. Paid another way? Press **Record payment** on the invoice. The page lists the payments with their receipts, the automatic debits, the emails sent and the history.
4. **Resend email** sends the invoice again. **PDF** opens it as a PDF.

## Correct an issued invoice

An issued invoice is never edited. You void it and issue a corrected one.

1. Press **Void**, write the reason (the owner reads it), keep Make a corrected invoice from it ticked, and press **Void the invoice**. Its scheduled debit is cancelled and the owner is told.
2. The corrected invoice opens as a draft with the same lines. Fix the amounts and press **Save and issue**.
3. Already paid? Void the payment first, or press **Credit note** for the amount to give back: it gets its own number and the owner sees it.

Invoices issued before October 20, 2026 at the old default (for example $904.00, or $1,017.00 when the Insurance Fee was $450.00) are not changed by themselves. Where an owner agreed another amount, void them and reissue at the agreed amount.

## The automatic debit

The debit runs by itself. Your job is to watch for returned debits and owners without a mandate.

:::flow
Notice day | Invoices issued, one notice per owner, 10 days before
Debit day | The 15th from 6:00: one debit per invoice
Cleared | The invoice is paid
Returned, insufficient funds | The $50.00 Late Fee is added once; the same amount is tried again within 30 days
Returned for another reason | No retry and no Late Fee: the debit pauses and you get a task
:::

1. The tiles show the next debit day and notice day, scheduled, processing, cleared and returned debits.
2. How it runs explains the policy in words, read from Program settings.
3. Scheduled and processing lists each debit. **Pause** holds one (a reason is needed).
4. Owners lists each mandate. Use **Pause**, **Resume** or **Send a notice now**.

![](/guides/img/admin-15-owner-debits-desktop-f65f061a.jpg "desktop; size: 1440 920; address: carmacars.ca/admin/debits; pins: 1 21.8 21.7, 2 21.5 35.5, 3 91.5 75.4, 4 84.7 94.7")

5. Results: each debit, cleared or returned, with the bank''s reason.
6. Run log: each notice and debit run, with its counts.
7. Notices sent: who was told what, for which debit day.

![](/guides/img/admin-15-owner-debits-desktop-8d4682bc.jpg "desktop; size: 1230 520; address: carmacars.ca/admin/debits; pins: 5 11.0 14.4, 6 10.2 52.3, 7 15.4 89.8")

Insufficient funds: the $50.00 Late Fee is added to that invoice once and collected with the owner''s next debit, and the original amount is tried again within 30 days, as section 4.4 of the Enrollment Agreement sets out. The retry is never more than the original amount. Returned again: the invoice is in arrears and you get a task.

> Watch out: Returned for any other reason (account closed, payment stopped, no authorization): there is no retry and no Late Fee. The owner''s debit pauses, the owner gets an email asking them to fix the account or pay another way, and you get a task. A debit is never more than its notice said. An owner with no mandate gets an email on the notice day and you get a task; nothing is debited for them.

## Owner statements

**Money** > **Owner statements**

1. Press **Build all for a month** (or **Build one**).
2. Open each draft. Check it, **Rebuild** after a correction, **Preview PDF**, then **Approve**.
3. Press **Issue to the owner**. **Reissue** sends a corrected copy; **CSV** exports it.

![](/guides/img/admin-16-statements-desktop-43a313ea.jpg "desktop; size: 1440 400; address: carmacars.ca/admin/statements; pins: 1 79.9 27.3")

![An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts.](/guides/img/admin-17-statement-desktop-106ee57f.jpg "desktop; size: 1440 520; address: carmacars.ca/admin/statements/f27936a8-9bfb-4280-81ae-c67ec47febe1; pins: 3 86.0 22.7")

## Staff commissions

**Money** > **Staff commissions**. Nothing is paid automatically.

:::flow
Not earned yet | The rental is ahead, or not paid in full
Pending approval | Completed and paid in full; a Sales month once it has ended
Approved | You approved it; the staff member is told
Paid | You recorded the payment; the staff member is told
Reversed | Cancelled, refunded or charged back; after payment it comes off the next payment
:::

1. By person shows each staff member''s month (Sales: rental days of 100 and the tier), what is not earned yet, pending approval, approved and paid.
2. Press **Approve** on a person (everything that may be approved now) or on one commission.
3. Press **Record a payment**: choose how it was paid (e-Transfer, bank transfer, Wise, cash, the monthly pay statement or another way), the reference and the date.
4. **Prices to review** lists prices typed by hand; **Sourcing claims** lists staff who say they sourced a website request; **Payments made** lists each payment.

|  | Commission |
| --- | --- |
| Sales | By rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all that month''s rentals |
| Customer service, finance, fleet, field staff | 10% (also the field referral fee) |
| Base | The rental charge before tax, after discounts, with late extra days; never delivery, kilometres, add-ons or anything else bought. Only a refund of the rental charge comes off |
| On the owner statement | An owner''s car: deducted with the kickbacks before Owner Revenue, its own line on the statement. A partner''s car: from CarmaCars'' commission. A CarmaCars-owned car: a CarmaCars expense |

> Tip: A commission that changes after an owner statement was built (a refund, or the month''s Sales tier) goes on the owner''s next statement as an adjustment line.

## Field pay

**Money** > **Field pay**. Field staff clock in and out on their phones (My hours); you run the pay every two weeks. Nothing is paid automatically.

:::flow
Clocked in and out | Field staff press Clock in and Clock out; Fleet or you fix a forgotten clock-out
Pay run started | Hours times the hourly rate, plus the approved commissions
Approved | The figures are frozen, the period''s hours are locked, the statements are numbered
Paid | You recorded how each person was paid; they get their statement by email
:::

1. The tab **Pay run** shows the current two-week period (Sunday to Saturday: the first day is Settings > Program, Field pay). **Earlier period** and **Later period** move between periods.
2. After the period ends, press **Start the pay run**: one line for each person with hours times their hourly rate, plus the staff commissions and referral fees approved by the end of the period (see Staff commissions). **Refresh the figures** takes in a change made since.
3. Press **Approve**. The period''s hours are locked, each line gets a statement number and the figures are frozen. Someone still clocked in blocks it: fix their shift under **Hours** first. **Withdraw** takes an approved run back while no payment is recorded.
4. Press **Record payment** on a line: choose e-Transfer, bank transfer or cash, the reference (not needed for cash) and the date. The commissions in the line are marked paid and the person gets their pay statement by email (**Send again** repeats it). The statement''s number opens its PDF; **CSV** gives the run for your accountant.
5. **Hours** lists everyone''s shifts of the period. **Add hours** enters a shift for someone who forgot to clock in, **Change** fixes one and **Remove** takes one out. Each needs a reason and is kept in a log. Fleet does the same under Field hours but sees no pay.
6. **Hourly rates** shows each person''s rate: CA$18.00 an hour unless you give them their own with **Set the rate** (a reason is needed). A pay run keeps the rate it was started with.

|  | Field pay |
| --- | --- |
| Overtime | Off. Settings > Program, Field pay: pay overtime, after 44 hours in a week, at 150% of the rate |
| Vacation pay | Off. Settings > Program, Field pay: vacation pay (Ontario: 4%) adds that share of wages, overtime and commissions to each statement |
| Deductions | None are worked out: income tax, CPP, EI and the employer''s contributions are for your accountant. Each statement says so |
| Commissions that net to nothing | A person whose approved commissions add up to nothing or less (a clawback) is not paid them this period: they carry to the next |

> Tip: A shift of more than 16 hours (a setting) is refused, and so are hours that overlap another shift of the same person. The field staff member sees their hours and statements under My hours on their phone.

## Company statements

CarmaCars'' own monthly statement, in twelve sections.

1. Choose the month. The tiles show revenue, fees, refunds, expenses and the company net.
2. Switch between Total, Per owner and Per vehicle.
3. Download **PDF**, **PDF by owner** or **PDF by vehicle**, or press **Email me the PDFs**.
4. **Finalize** freezes the month. **Rebuild** works until then.

![](/guides/img/admin-18-company-statements-desktop-8e2738ed.jpg "desktop; size: 1440 760; address: carmacars.ca/admin/reports; pins: 1 20.8 28.0, 2 19.4 59.3, 3 77.1 15.5, 4 46.9 15.5")
',
  '<p class="gd-p">Owner fee invoices are issued on the notice day and debited on the 15th. Invoices of any amount are made by hand, as drafts first. Statements are built, approved and issued each month, and payouts follow.</p><section class="gd-task" id="owner-money-owner-invoices" data-gd-task><h2 class="gd-h2">Owner invoices</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Owner invoices</b>. Every owner invoice, drafts and voids included. The same list is on each owner&#39;s and each application&#39;s Invoices tab.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Filter by Drafts, Open, Partly paid, Paid, Failed, In arrears or Void, or search by invoice number or owner. Open an invoice to see everything about it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">New invoice</b> makes an invoice of any amount for an owner&#39;s car, for example a registration fee of $123.45.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The monthly run and tracker invoices: <b class="gd-ui">Run the monthly invoices</b> issues the invoices for the 15th by hand, for a missed month (never twice); <b class="gd-ui">Issue all tracker invoices</b> bills the Tracker Install for each car waiting for its tracker.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/invoices</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1060"><img src="/guides/img/admin-14-owner-invoices-desktop-dc4ed1f1.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1060"><span class="gd-pin" style="left:83.3%;top:22.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:41.7%;top:35.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:29%;top:43.4%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="owner-money-make-edit-and-issue-an-invoice" data-gd-task><h2 class="gd-h2">Make, edit and issue an invoice</h2><p class="gd-p">A new invoice is a draft: the owner sees nothing and it is never debited until you issue it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose the car, a title (for example Registration fee) and, if you like, the due date (empty: 7 days after it is issued). Each line: the description, the quantity, the unit amount to the cent, HST on or off, and a note. <b class="gd-ui">Add a line</b> for more.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Save as draft</b> to come back to it, or <b class="gd-ui">Save and issue</b> to send it now. On a draft&#39;s page, <b class="gd-ui">Issue and email</b> sends it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Paid another way? Press <b class="gd-ui">Record payment</b> on the invoice. The page lists the payments with their receipts, the automatic debits, the emails sent and the history.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Resend email</b> sends the invoice again. <b class="gd-ui">PDF</b> opens it as a PDF.</div></li></ol></div></section><section class="gd-task" id="owner-money-correct-an-issued-invoice" data-gd-task><h2 class="gd-h2">Correct an issued invoice</h2><p class="gd-p">An issued invoice is never edited. You void it and issue a corrected one.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Void</b>, write the reason (the owner reads it), keep Make a corrected invoice from it ticked, and press <b class="gd-ui">Void the invoice</b>. Its scheduled debit is cancelled and the owner is told.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The corrected invoice opens as a draft with the same lines. Fix the amounts and press <b class="gd-ui">Save and issue</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Already paid? Void the payment first, or press <b class="gd-ui">Credit note</b> for the amount to give back: it gets its own number and the owner sees it.</div></li></ol></div><p class="gd-p">Invoices issued before October 20, 2026 at the old default (for example $904.00, or $1,017.00 when the Insurance Fee was $450.00) are not changed by themselves. Where an owner agreed another amount, void them and reissue at the agreed amount.</p></section><section class="gd-task" id="owner-money-the-automatic-debit" data-gd-task><h2 class="gd-h2">The automatic debit</h2><p class="gd-p">The debit runs by itself. Your job is to watch for returned debits and owners without a mandate.</p><ol class="gd-flow"><li><b>1</b><span>Notice day</span><em>Invoices issued, one notice per owner, 10 days before</em></li><li><b>2</b><span>Debit day</span><em>The 15th from 6:00: one debit per invoice</em></li><li><b>3</b><span>Cleared</span><em>The invoice is paid</em></li><li><b>4</b><span>Returned, insufficient funds</span><em>The $50.00 Late Fee is added once; the same amount is tried again within 30 days</em></li><li><b>5</b><span>Returned for another reason</span><em>No retry and no Late Fee: the debit pauses and you get a task</em></li></ol><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The tiles show the next debit day and notice day, scheduled, processing, cleared and returned debits.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">How it runs explains the policy in words, read from Program settings.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Scheduled and processing lists each debit. <b class="gd-ui">Pause</b> holds one (a reason is needed).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Owners lists each mandate. Use <b class="gd-ui">Pause</b>, <b class="gd-ui">Resume</b> or <b class="gd-ui">Send a notice now</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/debits</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/920"><img src="/guides/img/admin-15-owner-debits-desktop-f65f061a.jpg" alt="" loading="lazy" decoding="async" width="1440" height="920"><span class="gd-pin" style="left:21.8%;top:21.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:21.5%;top:35.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:91.5%;top:75.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:84.7%;top:94.7%" aria-hidden="true">4</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="5"><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Results: each debit, cleared or returned, with the bank&#39;s reason.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Run log: each notice and debit run, with its counts.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Notices sent: who was told what, for which debit day.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/debits</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/520"><img src="/guides/img/admin-15-owner-debits-desktop-8d4682bc.jpg" alt="" loading="lazy" decoding="async" width="1230" height="520"><span class="gd-pin" style="left:11%;top:14.4%" aria-hidden="true">5</span><span class="gd-pin" style="left:10.2%;top:52.3%" aria-hidden="true">6</span><span class="gd-pin" style="left:15.4%;top:89.8%" aria-hidden="true">7</span></div></div></figure></div><p class="gd-p">Insufficient funds: the $50.00 Late Fee is added to that invoice once and collected with the owner&#39;s next debit, and the original amount is tried again within 30 days, as section 4.4 of the Enrollment Agreement sets out. The retry is never more than the original amount. Returned again: the invoice is in arrears and you get a task.</p><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Returned for any other reason (account closed, payment stopped, no authorization): there is no retry and no Late Fee. The owner&#39;s debit pauses, the owner gets an email asking them to fix the account or pay another way, and you get a task. A debit is never more than its notice said. An owner with no mandate gets an email on the notice day and you get a task; nothing is debited for them.</div></aside></section><section class="gd-task" id="owner-money-owner-statements" data-gd-task><h2 class="gd-h2">Owner statements</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Owner statements</b></p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Build all for a month</b> (or <b class="gd-ui">Build one</b>).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open each draft. Check it, <b class="gd-ui">Rebuild</b> after a correction, <b class="gd-ui">Preview PDF</b>, then <b class="gd-ui">Approve</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Issue to the owner</b>. <b class="gd-ui">Reissue</b> sends a corrected copy; <b class="gd-ui">CSV</b> exports it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/statements</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/400"><img src="/guides/img/admin-16-statements-desktop-43a313ea.jpg" alt="" loading="lazy" decoding="async" width="1440" height="400"><span class="gd-pin" style="left:79.9%;top:27.3%" aria-hidden="true">1</span></div></div></figure></div><div class="gd-figblock"><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/statements/f27936a8-9bfb-4280-81ae-c67ec47febe1</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/520"><img src="/guides/img/admin-17-statement-desktop-106ee57f.jpg" alt="An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts." loading="lazy" decoding="async" width="1440" height="520"><span class="gd-pin" style="left:86%;top:22.7%" aria-hidden="true">3</span></div></div><figcaption>An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts.</figcaption></figure></div></section><section class="gd-task" id="owner-money-staff-commissions" data-gd-task><h2 class="gd-h2">Staff commissions</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Staff commissions</b>. Nothing is paid automatically.</p><ol class="gd-flow"><li><b>1</b><span>Not earned yet</span><em>The rental is ahead, or not paid in full</em></li><li><b>2</b><span>Pending approval</span><em>Completed and paid in full; a Sales month once it has ended</em></li><li><b>3</b><span>Approved</span><em>You approved it; the staff member is told</em></li><li><b>4</b><span>Paid</span><em>You recorded the payment; the staff member is told</em></li><li><b>5</b><span>Reversed</span><em>Cancelled, refunded or charged back; after payment it comes off the next payment</em></li></ol><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">By person shows each staff member&#39;s month (Sales: rental days of 100 and the tier), what is not earned yet, pending approval, approved and paid.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Approve</b> on a person (everything that may be approved now) or on one commission.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Record a payment</b>: choose how it was paid (e-Transfer, bank transfer, Wise, cash, the monthly pay statement or another way), the reference and the date.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Prices to review</b> lists prices typed by hand; <b class="gd-ui">Sourcing claims</b> lists staff who say they sourced a website request; <b class="gd-ui">Payments made</b> lists each payment.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col"></th><th scope="col">Commission</th></tr></thead><tbody><tr><td>Sales</td><td>By rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all that month&#39;s rentals</td></tr><tr><td>Customer service, finance, fleet, field staff</td><td>10% (also the field referral fee)</td></tr><tr><td>Base</td><td>The rental charge before tax, after discounts, with late extra days; never delivery, kilometres, add-ons or anything else bought. Only a refund of the rental charge comes off</td></tr><tr><td>On the owner statement</td><td>An owner&#39;s car: deducted with the kickbacks before Owner Revenue, its own line on the statement. A partner&#39;s car: from CarmaCars&#39; commission. A CarmaCars-owned car: a CarmaCars expense</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A commission that changes after an owner statement was built (a refund, or the month&#39;s Sales tier) goes on the owner&#39;s next statement as an adjustment line.</div></aside></section><section class="gd-task" id="owner-money-field-pay" data-gd-task><h2 class="gd-h2">Field pay</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Field pay</b>. Field staff clock in and out on their phones (My hours); you run the pay every two weeks. Nothing is paid automatically.</p><ol class="gd-flow"><li><b>1</b><span>Clocked in and out</span><em>Field staff press Clock in and Clock out; Fleet or you fix a forgotten clock-out</em></li><li><b>2</b><span>Pay run started</span><em>Hours times the hourly rate, plus the approved commissions</em></li><li><b>3</b><span>Approved</span><em>The figures are frozen, the period&#39;s hours are locked, the statements are numbered</em></li><li><b>4</b><span>Paid</span><em>You recorded how each person was paid; they get their statement by email</em></li></ol><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The tab <b class="gd-ui">Pay run</b> shows the current two-week period (Sunday to Saturday: the first day is Settings &gt; Program, Field pay). <b class="gd-ui">Earlier period</b> and <b class="gd-ui">Later period</b> move between periods.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">After the period ends, press <b class="gd-ui">Start the pay run</b>: one line for each person with hours times their hourly rate, plus the staff commissions and referral fees approved by the end of the period (see Staff commissions). <b class="gd-ui">Refresh the figures</b> takes in a change made since.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Approve</b>. The period&#39;s hours are locked, each line gets a statement number and the figures are frozen. Someone still clocked in blocks it: fix their shift under <b class="gd-ui">Hours</b> first. <b class="gd-ui">Withdraw</b> takes an approved run back while no payment is recorded.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Record payment</b> on a line: choose e-Transfer, bank transfer or cash, the reference (not needed for cash) and the date. The commissions in the line are marked paid and the person gets their pay statement by email (<b class="gd-ui">Send again</b> repeats it). The statement&#39;s number opens its PDF; <b class="gd-ui">CSV</b> gives the run for your accountant.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Hours</b> lists everyone&#39;s shifts of the period. <b class="gd-ui">Add hours</b> enters a shift for someone who forgot to clock in, <b class="gd-ui">Change</b> fixes one and <b class="gd-ui">Remove</b> takes one out. Each needs a reason and is kept in a log. Fleet does the same under Field hours but sees no pay.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><b class="gd-ui">Hourly rates</b> shows each person&#39;s rate: CA$18.00 an hour unless you give them their own with <b class="gd-ui">Set the rate</b> (a reason is needed). A pay run keeps the rate it was started with.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col"></th><th scope="col">Field pay</th></tr></thead><tbody><tr><td>Overtime</td><td>Off. Settings &gt; Program, Field pay: pay overtime, after 44 hours in a week, at 150% of the rate</td></tr><tr><td>Vacation pay</td><td>Off. Settings &gt; Program, Field pay: vacation pay (Ontario: 4%) adds that share of wages, overtime and commissions to each statement</td></tr><tr><td>Deductions</td><td>None are worked out: income tax, CPP, EI and the employer&#39;s contributions are for your accountant. Each statement says so</td></tr><tr><td>Commissions that net to nothing</td><td>A person whose approved commissions add up to nothing or less (a clawback) is not paid them this period: they carry to the next</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A shift of more than 16 hours (a setting) is refused, and so are hours that overlap another shift of the same person. The field staff member sees their hours and statements under My hours on their phone.</div></aside></section><section class="gd-task" id="owner-money-company-statements" data-gd-task><h2 class="gd-h2">Company statements</h2><p class="gd-p">CarmaCars&#39; own monthly statement, in twelve sections.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose the month. The tiles show revenue, fees, refunds, expenses and the company net.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Switch between Total, Per owner and Per vehicle.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Download <b class="gd-ui">PDF</b>, <b class="gd-ui">PDF by owner</b> or <b class="gd-ui">PDF by vehicle</b>, or press <b class="gd-ui">Email me the PDFs</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Finalize</b> freezes the month. <b class="gd-ui">Rebuild</b> works until then.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/reports</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/760"><img src="/guides/img/admin-18-company-statements-desktop-8e2738ed.jpg" alt="" loading="lazy" decoding="async" width="1440" height="760"><span class="gd-pin" style="left:20.8%;top:28%" aria-hidden="true">1</span><span class="gd-pin" style="left:19.4%;top:59.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.1%;top:15.5%" aria-hidden="true">3</span><span class="gd-pin" style="left:46.9%;top:15.5%" aria-hidden="true">4</span></div></div></figure></div></section>');
select app.guide_release_section('admin', 'settings', 'chapter', 'search-car-pages-landing-pages-and-guides', 'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: Blind Spot''s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Text alerts, Partners (each partner company''s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Deposits: the toll and ticket window after the return (7 days: settling sooner suggests a hold-back), the longest hold-back (30 days after the return), how long before a card hold lapses it is collected (36 hours), and collecting what is owed after the deposit by itself (the card on file, then a pay link, then a Finance task). A deposit is never released by itself.
9. Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-out besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task).
10. Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.
11. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
12. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Official ServiceOntario forms

The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "Signed here by hand, in ink"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with **Record paper signature**. Each form not checked yet is also a line on To do with the same button and Preview it.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form''s notes list what to tick or choose at the counter.

## Blind Spot rental agreement

We rent under Blind Spot Car Rental''s insurance, so every booking has two agreements: CarmaCars'' rental agreement and Blind Spot''s own. Blind Spot''s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.

1. Open **Settings** > **Forms**. The Blind Spot Car Rental agreement card is first. Press **Upload Blind Spot''s PDF** and choose Blind Spot''s blank form (2 pages, A4).
2. Press **Download the filled sample**: a made-up booking on the form. **Sample billed to an insurer** also fills the claim number, the adjuster and the insurance company. Check every box.
3. On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars'' HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative''s signature instead of Sam''s.
4. Press **Checked: use for bookings**. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.
5. Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.
6. A new version of Blind Spot''s form? Upload it the same way: it waits for **Checked: use for bookings**, and bookings keep the version in use until then.

> Good to know: Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.

The renter''s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking''s Drivers and documents tab, in the renter''s Documents, and the signed Blind Spot agreement is attached to the "Your signed rental agreement" email. Admin > Today lists the HST number, the upload and the check until they are done.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Your own PDF instead? **Send a PDF to sign** still works.
7. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
8. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.

## Promo codes: end dates and reminders

**Settings** > **All settings**, **Promo codes**.

- Every code made for a person has an end date: a game prize 7 days, a come-back offer 30, a Live visitors code 3 and a code made for one renter 30 unless you set another. The first card of Promo codes holds the 30 days and the two reminders.
- A code for everyone may have no end date: empty Valid until. The Add form starts with an end date 30 days ahead.
- A code that ended is refused wherever it is typed (the request form, an offer, Add a rental, a booking edit) with "This code has expired".
- A person who has not used a code is reminded 3 days before its last day and the day before, by email and by text as they chose, never once they used it, unsubscribed or the code ended, and never twice. A game code reminder always goes; a reminder of any other code needs their consent to offers.
- The list shows each code''s end date and the reminders sent. The card Codes sent to people lists game prizes, come-back offers and Live visitors codes the same way.

## Card coverage: which credit cards include rental car coverage

**Settings** > **Card coverage** is the list renters see at `carmacars.ca/credit-card-rental-coverage` and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.

1. The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer''s own document, and when it was last checked.
2. Open a card under Change a card, open its official guide, correct what changed and press **Save**. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.
3. A card whose numbers come from a published summary has Read in the issuer''s own document unticked and the summary''s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer''s guide.
4. Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.

> Tip: A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer''s guide.

## Reviews: review requests and Google

**Settings** > **Reviews**: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.

1. When review requests go: the check-in (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-in), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.
2. The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile''s own review link.
3. Google Business Profile: press **Connect Google** and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.
4. A clear match stops that renter''s reminders at once. A possible match waits in Reviews: press **Confirm**, **Not this renter** or **Match to a booking**.

> Tip: Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and "I already left a review", Mark reviewed and on-site reviews still stop the messages.
', 'Settings', 'Site, program settings, official forms mapping, insurers and the other lists.',
  'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: Blind Spot''s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Vehicle class rules, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Text alerts, Partners (each partner company''s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.

## Program settings

1. Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Deposits: the toll and ticket window after the return (7 days: settling sooner suggests a hold-back), the longest hold-back (30 days after the return), how long before a card hold lapses it is collected (36 hours), and collecting what is owed after the deposit by itself (the card on file, then a pay link, then a Finance task). A deposit is never released by itself.
9. Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-out besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task). Field pay: the first day of a pay period (every period is two weeks), the default hourly rate (CA$18.00), whether overtime is paid (off), after how many hours in a week (44) and at what share of the rate (150%), vacation pay added to each statement (off; Ontario 4%) and the longest shift (16 hours).
10. Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.
11. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
12. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")

## Vehicle class rules

Open **Settings**, then **Vehicle class rules**. How a new car''s class is decided from its VIN: the first rule that matches wins.

1. The table lists each rule: its rank, what the car must be (a make, and patterns for the model, the trim and the body), the class it gets, the class once the car is old enough, a note and whether it is on. The lowest rank that matches is used; a car that matches no rule is Standard.
2. Press **Add a rule** or **Change**: a rank, at least one condition, the class, optionally the years old after which an older class applies, and a note (it is shown as the reason for the class). A pattern is not case sensitive: ^911 matches models that start with 911. A rule with no condition, a pattern that does not compile and an older class equal to the class are refused.
3. **Try a car** gives the class the rules decide for a year, make, model, trim and body, and why.
4. **Delete** removes a rule; switch it off instead to keep it. Every add, change and delete is in the audit log, with before and after.

> Tip: A rule changes the cars entered from then on. A car already listed keeps its class until you change it on the car.

## Official ServiceOntario forms

The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Press **Download a filled preview** for one car and check each value against the form.
3. Change a field if needed: What goes in it (or "Signed here by hand, in ink"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with **Record paper signature**. Each form not checked yet is also a line on To do with the same button and Preview it.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form''s notes list what to tick or choose at the counter.

## Blind Spot rental agreement

We rent under Blind Spot Car Rental''s insurance, so every booking has two agreements: CarmaCars'' rental agreement and Blind Spot''s own. Blind Spot''s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.

1. Open **Settings** > **Forms**. The Blind Spot Car Rental agreement card is first. Press **Upload Blind Spot''s PDF** and choose Blind Spot''s blank form (2 pages, A4).
2. Press **Download the filled sample**: a made-up booking on the form. **Sample billed to an insurer** also fills the claim number, the adjuster and the insurance company. Check every box.
3. On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars'' HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative''s signature instead of Sam''s.
4. Press **Checked: use for bookings**. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.
5. Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.
6. A new version of Blind Spot''s form? Upload it the same way: it waits for **Checked: use for bookings**, and bookings keep the version in use until then.

> Good to know: Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.

The renter''s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking''s Drivers and documents tab, in the renter''s Documents, and the signed Blind Spot agreement is attached to the "Your signed rental agreement" email. Admin > Today lists the HST number, the upload and the check until they are done.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, or on paper.

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Staff**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Your own PDF instead? **Send a PDF to sign** still works.
7. Signed on paper instead? Press **Record paper signature** in the same place and upload the scan.
8. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.

## Promo codes: end dates and reminders

**Settings** > **All settings**, **Promo codes**.

- Every code made for a person has an end date: a game prize 7 days, a come-back offer 30, a Live visitors code 3 and a code made for one renter 30 unless you set another. The first card of Promo codes holds the 30 days and the two reminders.
- A code for everyone may have no end date: empty Valid until. The Add form starts with an end date 30 days ahead.
- A code that ended is refused wherever it is typed (the request form, an offer, Add a rental, a booking edit) with "This code has expired".
- A person who has not used a code is reminded 3 days before its last day and the day before, by email and by text as they chose, never once they used it, unsubscribed or the code ended, and never twice. A game code reminder always goes; a reminder of any other code needs their consent to offers.
- The list shows each code''s end date and the reminders sent. The card Codes sent to people lists game prizes, come-back offers and Live visitors codes the same way.

## Card coverage: which credit cards include rental car coverage

**Settings** > **Card coverage** is the list renters see at `carmacars.ca/credit-card-rental-coverage` and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.

1. The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer''s own document, and when it was last checked.
2. Open a card under Change a card, open its official guide, correct what changed and press **Save**. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.
3. A card whose numbers come from a published summary has Read in the issuer''s own document unticked and the summary''s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer''s guide.
4. Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.

> Tip: A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer''s guide.

## Reviews: review requests and Google

**Settings** > **Reviews**: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.

1. When review requests go: the check-in (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-in), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.
2. The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile''s own review link.
3. Google Business Profile: press **Connect Google** and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.
4. A clear match stops that renter''s reminders at once. A possible match waits in Reviews: press **Confirm**, **Not this renter** or **Match to a booking**.

> Tip: Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and "I already left a review", Mark reviewed and on-site reviews still stop the messages.
',
  '<p class="gd-p">Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.</p><section class="gd-task" id="settings-the-settings-page" data-gd-task><h2 class="gd-h2">The Settings page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Site setup lists what is still missing on the public site, with <b class="gd-ui">Open site settings</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Program settings: every timing and policy value.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Forms: Blind Spot&#39;s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Insurers: insurance companies billed for bookings.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-24-settings-desktop-89b31691.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:32.6%;top:33%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.8%;top:40.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:40.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:25.8%;top:73.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:25.8%;top:84.9%" aria-hidden="true">5</span></div></div></figure></div><p class="gd-p">The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Vehicle class rules, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Text alerts, Partners (each partner company&#39;s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.</p></section><section class="gd-task" id="settings-program-settings" data-gd-task><h2 class="gd-h2">Program settings</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month&#39;s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press <b class="gd-ui">Save the defaults</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Deposits: the toll and ticket window after the return (7 days: settling sooner suggests a hold-back), the longest hold-back (30 days after the return), how long before a card hold lapses it is collected (36 hours), and collecting what is owed after the deposit by itself (the card on file, then a pay link, then a Finance task). A deposit is never released by itself.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-out besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task). Field pay: the first day of a pay period (every period is two weeks), the default hourly rate (CA$18.00), whether overtime is paid (off), after how many hours in a week (44) and at what share of the rate (150%), vacation pay added to each statement (off; Ontario 4%) and the longest shift (16 hours).</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.</div></li><li><span class="gd-n" aria-hidden="true">11</span><div class="gd-t">Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.</div></li><li><span class="gd-n" aria-hidden="true">12</span><div class="gd-t">Change a value and press <b class="gd-ui">Save</b>. It is saved as a new row from today; the rows before stay as they were.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/program</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/admin-25-program-settings-desktop-d16b066c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:25.8%;top:22%" aria-hidden="true">1</span><span class="gd-pin" style="left:27.8%;top:49%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="settings-vehicle-class-rules" data-gd-task><h2 class="gd-h2">Vehicle class rules</h2><p class="gd-p">Open <b class="gd-ui">Settings</b>, then <b class="gd-ui">Vehicle class rules</b>. How a new car&#39;s class is decided from its VIN: the first rule that matches wins.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The table lists each rule: its rank, what the car must be (a make, and patterns for the model, the trim and the body), the class it gets, the class once the car is old enough, a note and whether it is on. The lowest rank that matches is used; a car that matches no rule is Standard.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Add a rule</b> or <b class="gd-ui">Change</b>: a rank, at least one condition, the class, optionally the years old after which an older class applies, and a note (it is shown as the reason for the class). A pattern is not case sensitive: ^911 matches models that start with 911. A rule with no condition, a pattern that does not compile and an older class equal to the class are refused.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Try a car</b> gives the class the rules decide for a year, make, model, trim and body, and why.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Delete</b> removes a rule; switch it off instead to keep it. Every add, change and delete is in the audit log, with before and after.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A rule changes the cars entered from then on. A car already listed keeps its class until you change it on the car.</div></aside></section><section class="gd-task" id="settings-official-serviceontario-forms" data-gd-task><h2 class="gd-h2">Official ServiceOntario forms</h2><p class="gd-p">The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. Each form shows &quot;Mapping to check&quot; (a draft is ready) or &quot;Official PDF in use&quot;. Its notes say what the form is for and which boxes are left blank on purpose.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download a filled preview</b> for one car and check each value against the form.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change a field if needed: What goes in it (or &quot;Signed here by hand, in ink&quot;), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for owners</b>. Every owner&#39;s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with <b class="gd-ui">Record paper signature</b>. Each form not checked yet is also a line on To do with the same button and Preview it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A new version from ServiceOntario? Press <b class="gd-ui">Upload the official fillable PDF</b>: the fields of the same name keep their mapping.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company&#39;s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner&#39;s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form&#39;s notes list what to tick or choose at the counter.</div></aside></section><section class="gd-task" id="settings-blind-spot-rental-agreement" data-gd-task><h2 class="gd-h2">Blind Spot rental agreement</h2><p class="gd-p">We rent under Blind Spot Car Rental&#39;s insurance, so every booking has two agreements: CarmaCars&#39; rental agreement and Blind Spot&#39;s own. Blind Spot&#39;s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. The Blind Spot Car Rental agreement card is first. Press <b class="gd-ui">Upload Blind Spot&#39;s PDF</b> and choose Blind Spot&#39;s blank form (2 pages, A4).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download the filled sample</b>: a made-up booking on the form. <b class="gd-ui">Sample billed to an insurer</b> also fills the claim number, the adjuster and the insurance company. Check every box.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars&#39; HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative&#39;s signature instead of Sam&#39;s.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for bookings</b>. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A new version of Blind Spot&#39;s form? Upload it the same way: it waits for <b class="gd-ui">Checked: use for bookings</b>, and bookings keep the version in use until then.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.</div></aside><p class="gd-p">The renter&#39;s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking&#39;s Drivers and documents tab, in the renter&#39;s Documents, and the signed Blind Spot agreement is attached to the &quot;Your signed rental agreement&quot; email. Admin &gt; Today lists the HST number, the upload and the check until they are done.</p></section><section class="gd-task" id="settings-agreements-to-sign-investors-and-staff" data-gd-task><h2 class="gd-h2">Agreements to sign: investors and staff</h2><p class="gd-p">Investment agreements and staff agreements are made from the person&#39;s record and signed in their own portal, or on paper.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Investor: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Investors</b> and the investor. Under Investment agreement, press <b class="gd-ui">Send the agreement to sign</b>. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press <b class="gd-ui">Send to sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Once the investor signs, the agreement shows <b class="gd-ui">Awaiting countersignature</b> on the investor&#39;s page and on To do. It is not countersigned automatically: check it and press <b class="gd-ui">Countersign</b>. CarmaCars is bound once it has countersigned and the funds clear.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Staff: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Staff</b>. Under Staff agreements, press <b class="gd-ui">Send the agreement to sign</b> beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field staff member&#39;s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Your own PDF instead? <b class="gd-ui">Send a PDF to sign</b> still works.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Signed on paper instead? Press <b class="gd-ui">Record paper signature</b> in the same place and upload the scan.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Sent by mistake? Press <b class="gd-ui">Withdraw</b> and give the reason.</div></li></ol></div></section><section class="gd-task" id="settings-the-user-guides" data-gd-task><h2 class="gd-h2">The user guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Guides</b>. The guide of each portal, as people read it under Guide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each guide shows its version, when it was published and whether there are unpublished changes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a guide and press a section. Change its text and press <b class="gd-ui">Show the preview</b> to see it as people will. Press <b class="gd-ui">Save the draft</b>; each save is kept in the section&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Move a section with the arrows, hide it, or press <b class="gd-ui">Add a chapter</b>. Upload a screenshot under Screenshots and paste the line it gives you.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Publish version</b> (the next number). The portals show the new version at once.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.</div></li></ol></div></section><section class="gd-task" id="settings-the-guides-keep-up-by-themselves" data-gd-task><h2 class="gd-h2">The guides keep up by themselves</h2><p class="gd-p">After every update of the site that changes the portals, the guides are checked without anyone asking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal&#39;s own labels and menu, checked, and published. The PDFs of those guides are printed again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Such a section says <b class="gd-ui">Changed automatically on</b> and the date, in the list of guides and in the guide&#39;s editor. Not right? Open the section and press <b class="gd-ui">Revert</b>: the text it replaced comes back, published at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section&#39;s history. There is nothing to review.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The card &quot;The guides keep up by themselves&quot; at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.</div></aside></section><section class="gd-task" id="settings-insurers-and-the-other-lists" data-gd-task><h2 class="gd-h2">Insurers and the other lists</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press <b class="gd-ui">Add</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.</div></li></ol></div></section><section class="gd-task" id="settings-promo-codes-end-dates-and-reminders" data-gd-task><h2 class="gd-h2">Promo codes: end dates and reminders</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">All settings</b>, <b class="gd-ui">Promo codes</b>.</p><ul class="gd-ul"><li>Every code made for a person has an end date: a game prize 7 days, a come-back offer 30, a Live visitors code 3 and a code made for one renter 30 unless you set another. The first card of Promo codes holds the 30 days and the two reminders.</li><li>A code for everyone may have no end date: empty Valid until. The Add form starts with an end date 30 days ahead.</li><li>A code that ended is refused wherever it is typed (the request form, an offer, Add a rental, a booking edit) with &quot;This code has expired&quot;.</li><li>A person who has not used a code is reminded 3 days before its last day and the day before, by email and by text as they chose, never once they used it, unsubscribed or the code ended, and never twice. A game code reminder always goes; a reminder of any other code needs their consent to offers.</li><li>The list shows each code&#39;s end date and the reminders sent. The card Codes sent to people lists game prizes, come-back offers and Live visitors codes the same way.</li></ul></section><section class="gd-task" id="settings-card-coverage-which-credit-cards-include-rental-car-coverage" data-gd-task><h2 class="gd-h2">Card coverage: which credit cards include rental car coverage</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Card coverage</b> is the list renters see at <span class="gd-url">carmacars.ca/credit-card-rental-coverage</span> and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer&#39;s own document, and when it was last checked.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a card under Change a card, open its official guide, correct what changed and press <b class="gd-ui">Save</b>. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A card whose numbers come from a published summary has Read in the issuer&#39;s own document unticked and the summary&#39;s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer&#39;s guide.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer&#39;s guide.</div></aside></section><section class="gd-task" id="settings-reviews-review-requests-and-google" data-gd-task><h2 class="gd-h2">Reviews: review requests and Google</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Reviews</b>: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When review requests go: the check-in (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-in), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile&#39;s own review link.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Google Business Profile: press <b class="gd-ui">Connect Google</b> and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A clear match stops that renter&#39;s reminders at once. A possible match waits in Reviews: press <b class="gd-ui">Confirm</b>, <b class="gd-ui">Not this renter</b> or <b class="gd-ui">Match to a booking</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and &quot;I already left a review&quot;, Mark reviewed and on-site reviews still stop the messages.</div></aside></section>');
select app.guide_release_section('va', 'your-workday', 'chapter', 'start-here', 'Every function works the same way: start on To do, take the oldest task, finish it, and check Today for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.

## The menu

My work comes first: To do, Today at a glance, My scorecard and My sales. Customer service and Sales then have Live: Live chat, Live visitors and Game leads. Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.

| Function | Groups and pages |
| --- | --- |
| Customer service | Bookings (Requests, Chauffeur, Send an offer, Add a rental, New quote, Calendar, Find a car), Renters (Messages, Find a renter, Review requests, Card coverage), Cars (Listings, Similar cars), Owners (Owners and enquiries, Add a car for an owner, Owner forms) |
| Sales | Bookings (Requests and offers, Chauffeur, Send an offer, Add a rental, New quote, Calendar, Find a car, Card coverage), Owners (Owner leads) |
| Finance | Money (Payments by day, Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar), Rentals (Add a rental, New quote, Find a car, Card coverage) |
| Fleet | Field work (Field jobs, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar, Calendar sync, Add a car for an owner), Renters (Find a renter), Rentals (Add a rental, New quote, Find a car, Card coverage) |

## To do

Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more. To do puts the most urgent first.

1. The top shows your function, today''s date, how many things need you, your open, overdue and done-today figures, and your quickest actions.
2. **Next up** is the one task to do now. Press its button to do it, or **Take it** to make it yours.
3. Your lanes group the work, for example Booking requests, Renter messages, Texts and calls, Live chat and Offers out. Each shows how many are waiting and how long the oldest has waited. Replies are timed against the 5-minute first reply target: past it the time turns red and says late. The most urgent lane comes first; press a lane to open it.
4. Customer service and Sales: **Waiting for a reply** lists every request, renter message, missed call and chat, the longest wait first, each with its reply button. Sales also sees the commission ring and Follow-ups due, Fleet today''s handovers, returns and moves and the cars right now, Finance Money today.
5. **Every open task**: filter All, Mine, Unassigned or Waiting. Under More filters: Any time, Overdue, Due today or Escalated, and by type. Each row has a priority, the task, its record, when it is due and a live timer of how long it has waited.
6. Press **Take it** to make it yours. Pressing the task opens the screen where it is done: a chat waiting for a person opens that chat, documents to check open the review, a request opens the booking. **Sheet** opens the step-by-step procedure.
7. Tasks close by themselves when their work is done elsewhere (an invoice paid or voided, a chat answered or closed); a day''s opening and closing checks close at the end of that day.
8. On a computer, press **/** to search (Find a renter; Sales: Find a car).

![](/guides/img/va-cs-01-queue-desktop-c36a8e2d.jpg "desktop; size: 1440 640; address: carmacars.ca/va; pins: 1 13.9 5.0, 2 36.1 17.5, 3 31.9 43.8, 4 91.7 52.3")

## Work a task

Open the task. The buttons along the top move it on.

| Button | What it does |
| --- | --- |
| **Open the working screen** | Jumps to the booking, car or owner the task is about. |
| **Done** | You finished it. It leaves the queue. |
| **Waiting** | You are waiting on someone (a renter, an owner). It stays yours. |
| **Escalate** | It needs an Admin. Add why. |
| **Hand over** | Give it to someone else on the team. |
| **Add a note** | Leave a note for whoever looks next. |

> Tip: Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.

## Today

1. Today lists pickups and returns, and what is due, for your function.
2. Press a booking number to open it. **To do** takes you back to your tasks.

![](/guides/img/va-cs-02-today-desktop-dfd277b7.jpg "desktop; size: 1440 700; address: carmacars.ca/va/today; pins: 1 20.8 14.3")

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. The queue shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, hours, rate and start date), then press **Read the PDF** and read it.
3. Press **Sign**. Your full legal name is your signature (or press **Draw instead**). Several documents? One signature covers all of them. The signed copy stays on the same page.

## Several functions? Switch with Working as

If you cover more than one function, **Working as** above the menu lists them: Customer service, Finance, Fleet and Sales. Choose one; the menu, To do and Today change to that function.

## Your scorecard

1. Open **My work** > **My scorecard**.
2. By week shows each measure, its target and your result for each week.
3. A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.
4. The first reply target is 5 minutes: a new booking request, an enquiry, a change the renter asked for or a renter message is due 5 minutes after it comes in. An Admin sets it in Program settings, and the target column shows the one in force.

![](/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg "desktop; size: 1440 360; address: carmacars.ca/va/scorecard; pins: 1 4.2 39.7, 2 62.5 58.3")
', 'Your workday', 'The menu, To do, task actions, Today, switching functions and your scorecard.',
  'Every function works the same way: start on To do, take the oldest task, finish it, and check Today for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.

## The menu

My work comes first: To do, Today at a glance, My scorecard and My sales. Customer service and Sales then have Live: Live chat, Live visitors and Game leads. Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.

| Function | Groups and pages |
| --- | --- |
| Customer service | Bookings (Requests, Chauffeur, Send an offer, Add a rental, New quote, Calendar, Find a car), Renters (Messages, Find a renter, Review requests, Card coverage), Cars (Listings, Similar cars), Owners (Owners and enquiries, Add a car for an owner, Owner forms) |
| Sales | Bookings (Requests and offers, Chauffeur, Send an offer, Add a rental, New quote, Calendar, Find a car, Card coverage), Owners (Owner leads) |
| Finance | Money (Payments by day, Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar), Rentals (Add a rental, New quote, Find a car, Card coverage) |
| Fleet | Field work (Field jobs, Field hours, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar, Calendar sync, Add a car for an owner), Renters (Find a renter), Rentals (Add a rental, New quote, Find a car, Card coverage) |

## To do

Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more. To do puts the most urgent first.

1. The top shows your function, today''s date, how many things need you, your open, overdue and done-today figures, and your quickest actions.
2. **Next up** is the one task to do now. Press its button to do it, or **Take it** to make it yours.
3. Your lanes group the work, for example Booking requests, Renter messages, Texts and calls, Live chat and Offers out. Each shows how many are waiting and how long the oldest has waited. Replies are timed against the 5-minute first reply target: past it the time turns red and says late. The most urgent lane comes first; press a lane to open it.
4. Customer service and Sales: **Waiting for a reply** lists every request, renter message, missed call and chat, the longest wait first, each with its reply button. Sales also sees the commission ring and Follow-ups due, Fleet today''s handovers, returns and moves and the cars right now, Finance Money today.
5. **Every open task**: filter All, Mine, Unassigned or Waiting. Under More filters: Any time, Overdue, Due today or Escalated, and by type. Each row has a priority, the task, its record, when it is due and a live timer of how long it has waited.
6. Press **Take it** to make it yours. Pressing the task opens the screen where it is done: a chat waiting for a person opens that chat, documents to check open the review, a request opens the booking. **Sheet** opens the step-by-step procedure.
7. Tasks close by themselves when their work is done elsewhere (an invoice paid or voided, a chat answered or closed); a day''s opening and closing checks close at the end of that day.
8. On a computer, press **/** to search (Find a renter; Sales: Find a car).

![](/guides/img/va-cs-01-queue-desktop-c36a8e2d.jpg "desktop; size: 1440 640; address: carmacars.ca/va; pins: 1 13.9 5.0, 2 36.1 17.5, 3 31.9 43.8, 4 91.7 52.3")

## Work a task

Open the task. The buttons along the top move it on.

| Button | What it does |
| --- | --- |
| **Open the working screen** | Jumps to the booking, car or owner the task is about. |
| **Done** | You finished it. It leaves the queue. |
| **Waiting** | You are waiting on someone (a renter, an owner). It stays yours. |
| **Escalate** | It needs an Admin. Add why. |
| **Hand over** | Give it to someone else on the team. |
| **Add a note** | Leave a note for whoever looks next. |

> Tip: Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.

## Today

1. Today lists pickups and returns, and what is due, for your function.
2. Press a booking number to open it. **To do** takes you back to your tasks.

![](/guides/img/va-cs-02-today-desktop-dfd277b7.jpg "desktop; size: 1440 700; address: carmacars.ca/va/today; pins: 1 20.8 14.3")

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. The queue shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, hours, rate and start date), then press **Read the PDF** and read it.
3. Press **Sign**. Your full legal name is your signature (or press **Draw instead**). Several documents? One signature covers all of them. The signed copy stays on the same page.

## Several functions? Switch with Working as

If you cover more than one function, **Working as** above the menu lists them: Customer service, Finance, Fleet and Sales. Choose one; the menu, To do and Today change to that function.

## Your scorecard

1. Open **My work** > **My scorecard**.
2. By week shows each measure, its target and your result for each week.
3. A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.
4. The first reply target is 5 minutes: a new booking request, an enquiry, a change the renter asked for or a renter message is due 5 minutes after it comes in. An Admin sets it in Program settings, and the target column shows the one in force.

![](/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg "desktop; size: 1440 360; address: carmacars.ca/va/scorecard; pins: 1 4.2 39.7, 2 62.5 58.3")
',
  '<p class="gd-p">Every function works the same way: start on To do, take the oldest task, finish it, and check Today for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.</p><section class="gd-task" id="your-workday-the-menu" data-gd-task><h2 class="gd-h2">The menu</h2><p class="gd-p">My work comes first: To do, Today at a glance, My scorecard and My sales. Customer service and Sales then have Live: Live chat, Live visitors and Game leads. Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Function</th><th scope="col">Groups and pages</th></tr></thead><tbody><tr><td>Customer service</td><td>Bookings (Requests, Chauffeur, Send an offer, Add a rental, New quote, Calendar, Find a car), Renters (Messages, Find a renter, Review requests, Card coverage), Cars (Listings, Similar cars), Owners (Owners and enquiries, Add a car for an owner, Owner forms)</td></tr><tr><td>Sales</td><td>Bookings (Requests and offers, Chauffeur, Send an offer, Add a rental, New quote, Calendar, Find a car, Card coverage), Owners (Owner leads)</td></tr><tr><td>Finance</td><td>Money (Payments by day, Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar), Rentals (Add a rental, New quote, Find a car, Card coverage)</td></tr><tr><td>Fleet</td><td>Field work (Field jobs, Field hours, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar, Calendar sync, Add a car for an owner), Renters (Find a renter), Rentals (Add a rental, New quote, Find a car, Card coverage)</td></tr></tbody></table></div></section><section class="gd-task" id="your-workday-to-do" data-gd-task><h2 class="gd-h2">To do</h2><p class="gd-p">Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more. To do puts the most urgent first.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The top shows your function, today&#39;s date, how many things need you, your open, overdue and done-today figures, and your quickest actions.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Next up</b> is the one task to do now. Press its button to do it, or <b class="gd-ui">Take it</b> to make it yours.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Your lanes group the work, for example Booking requests, Renter messages, Texts and calls, Live chat and Offers out. Each shows how many are waiting and how long the oldest has waited. Replies are timed against the 5-minute first reply target: past it the time turns red and says late. The most urgent lane comes first; press a lane to open it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Customer service and Sales: <b class="gd-ui">Waiting for a reply</b> lists every request, renter message, missed call and chat, the longest wait first, each with its reply button. Sales also sees the commission ring and Follow-ups due, Fleet today&#39;s handovers, returns and moves and the cars right now, Finance Money today.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Every open task</b>: filter All, Mine, Unassigned or Waiting. Under More filters: Any time, Overdue, Due today or Escalated, and by type. Each row has a priority, the task, its record, when it is due and a live timer of how long it has waited.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Press <b class="gd-ui">Take it</b> to make it yours. Pressing the task opens the screen where it is done: a chat waiting for a person opens that chat, documents to check open the review, a request opens the booking. <b class="gd-ui">Sheet</b> opens the step-by-step procedure.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Tasks close by themselves when their work is done elsewhere (an invoice paid or voided, a chat answered or closed); a day&#39;s opening and closing checks close at the end of that day.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">On a computer, press <b class="gd-ui">/</b> to search (Find a renter; Sales: Find a car).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/va-cs-01-queue-desktop-c36a8e2d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:13.9%;top:5%" aria-hidden="true">1</span><span class="gd-pin" style="left:36.1%;top:17.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:31.9%;top:43.8%" aria-hidden="true">3</span><span class="gd-pin" style="left:91.7%;top:52.3%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="your-workday-work-a-task" data-gd-task><h2 class="gd-h2">Work a task</h2><p class="gd-p">Open the task. The buttons along the top move it on.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Button</th><th scope="col">What it does</th></tr></thead><tbody><tr><td><b class="gd-ui">Open the working screen</b></td><td>Jumps to the booking, car or owner the task is about.</td></tr><tr><td><b class="gd-ui">Done</b></td><td>You finished it. It leaves the queue.</td></tr><tr><td><b class="gd-ui">Waiting</b></td><td>You are waiting on someone (a renter, an owner). It stays yours.</td></tr><tr><td><b class="gd-ui">Escalate</b></td><td>It needs an Admin. Add why.</td></tr><tr><td><b class="gd-ui">Hand over</b></td><td>Give it to someone else on the team.</td></tr><tr><td><b class="gd-ui">Add a note</b></td><td>Leave a note for whoever looks next.</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.</div></aside></section><section class="gd-task" id="your-workday-today" data-gd-task><h2 class="gd-h2">Today</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Today lists pickups and returns, and what is due, for your function.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press a booking number to open it. <b class="gd-ui">To do</b> takes you back to your tasks.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/today</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/700"><img src="/guides/img/va-cs-02-today-desktop-dfd277b7.jpg" alt="" loading="lazy" decoding="async" width="1440" height="700"><span class="gd-pin" style="left:20.8%;top:14.3%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="your-workday-documents-to-sign" data-gd-task><h2 class="gd-h2">Documents to sign</h2><p class="gd-p">Your staff agreement, when CarmaCars sends it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The queue shows &quot;You have a document to sign&quot;. Press <b class="gd-ui">Read and sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the key values at the top (your role, hours, rate and start date), then press <b class="gd-ui">Read the PDF</b> and read it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Sign</b>. Your full legal name is your signature (or press <b class="gd-ui">Draw instead</b>). Several documents? One signature covers all of them. The signed copy stays on the same page.</div></li></ol></div></section><section class="gd-task" id="your-workday-several-functions-switch-with-working-as" data-gd-task><h2 class="gd-h2">Several functions? Switch with Working as</h2><p class="gd-p">If you cover more than one function, <b class="gd-ui">Working as</b> above the menu lists them: Customer service, Finance, Fleet and Sales. Choose one; the menu, To do and Today change to that function.</p></section><section class="gd-task" id="your-workday-your-scorecard" data-gd-task><h2 class="gd-h2">Your scorecard</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">My work</b> &gt; <b class="gd-ui">My scorecard</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">By week shows each measure, its target and your result for each week.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The first reply target is 5 minutes: a new booking request, an enquiry, a change the renter asked for or a renter message is due 5 minutes after it comes in. An Admin sets it in Program settings, and the target column shows the one in force.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/scorecard</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/360"><img src="/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg" alt="" loading="lazy" decoding="async" width="1440" height="360"><span class="gd-pin" style="left:4.2%;top:39.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:62.5%;top:58.3%" aria-hidden="true">2</span></div></div></figure></div></section>');
select app.guide_release_section('va', 'fleet', 'chapter', 'finance', 'You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listing pipeline with its duplicate check and plate covering.

Your rail: Queue, Today, Field jobs, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.

## Schedule field jobs

Every confirmed booking gets its handover (or delivery) and return (or pickup) jobs by itself, at the booking''s times and place, given to the field staff member with the fewest jobs that day. You check and change them.

1. Jobs, next three days: each with its place, its field staff and whether they acknowledged it. "Made from the booking" marks the ones made by themselves; when the booking moves, they move too, unless you changed them.
2. Change a job with **Assign**, **Reassign**, **Move** (time and place) or **Cancel**.
3. Handovers and returns without a job (when the automatic jobs are off, or one was cancelled) are listed first: press **Schedule**, the place filled in from the booking.
4. An Admin turns the automatic jobs or the assignment off in Settings > Program.

![](/guides/img/va-fleet-02-field-jobs-desktop-b985927b.jpg "desktop; size: 1230 1180; address: carmacars.ca/va/fleet; pins: 1 15.4 10.4, 2 78.9 12.7, 3 11.4 68.6, 4 78.9 83.9")

## Daily checks

Twice a day: the opening check by 9:00 and the closing check by 18:00.

1. Open **Daily checks** and choose **Opening check** or **Closing check**.
2. Each line shows what was found. Tick OK, or Problem with a note.
3. Press **Save the opening check** (or **Save the closing check**). You can save it again.

![](/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg "desktop; size: 1230 820; address: carmacars.ca/va/checks; pins: 1 6.5 15.4, 2 44.7 42.0, 3 64.2 94.0")

## Check a car out or in

Fleet, Sales and Customer service check cars out and in from the booking.

1. On a confirmed booking press **Check out (pickup)**; on a booking on rent, **Check in (return)**. Today lists the ones due, each with its button.
2. The checklist field staff use opens: readings (km and fuel or charge), the photo set with the plate and the gauges, damage close-ups and both signatures.
3. Afterwards press **Photo report**: times, Late by, kilometres, fuel, photos and the return charges. Fleet waives a charge with **Waive** and a reason.

## Photo reviews after a return

After each return, the field photo set waits under **Photo reviews**. Compare it with the pickup set. Press **Review done**, or **Ask for a re-shoot** if a photo is missing or unclear.

## Similar cars

A possible duplicate never keeps a car off the site: it shows on the car''s checklist until you decide. Only Same car takes it off.

1. Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.
2. Compare the permit, the plate and the photos.
3. Press **Not a duplicate** with a note when they are different cars, or **Same car** when they are.

![](/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg "desktop; size: 1230 460; address: carmacars.ca/va/similar-cars; pins: 1 23.6 30.4, 3 94.8 30.4")

## Rates and kilometres

From a listing, press **The car and its rates**, or open the car from Field jobs.

1. Type the rates an Admin set. Only the daily rate is needed; the others follow from it when empty. The weekend rate is a price per day for each day that starts on a Friday or Saturday.
2. Keep **Use the defaults** for the kilometres, or choose **Custom for this car**.
3. Check What renters pay under the fields, then press **Save the rates**. Rates, kilometres and deposit save together.

## Listings and covering plates

1. Open **Listings**. A draft waiting shows Needs review. Open it.
2. The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.

![](/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg "desktop; size: 1230 340; address: carmacars.ca/va/listings; pins: 1 54.5 49.1")

3. Press **Cover the plate**. Check the suggested box; **Suggest the plate** asks again.
4. Drag over a plate to draw a box; drag a box to move it, its corner to resize it.
5. Choose **A CarmaCars plate**, **Pixelation** or **Blur**, then **Save the covered photo**.
6. No plate in the shot? **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg "phone; size: 390 776; pins: 3 52.6 78.9, 4 50.0 43.8, 5 61.5 62.1, 6 43.1 92.3")

> Watch out: The plate check never holds a car back: a photo whose plate is not checked stays private, and goes public by itself once it is covered or marked. The covered photo replaces the public one; the original is kept privately.

## Publish now

Customer service and fleet publish a car themselves; nothing has to be finished first.

1. Open the car from Listings or Field jobs. Its listing says why it is not on the site yet; press **Publish now**. With no rates yet it uses the suggested rates (similar cars, else the class defaults).
2. What is still open (paperwork, details, photos, No VIN yet for a car added by its plate, a possible duplicate) shows as warnings after Publish now and on the car. None of them stops publishing.
3. New cars with their rates usually go on the site by themselves (Publish new cars automatically, on by default). A car taken off the site by staff waits for Publish now.

> Tip: A car not on the fleet insurance policy yet can be requested, offered and paid for, but never handed over until the insurer confirms it. Requests and offers for such a car show a warning.

## Calendar sync with Turo and other platforms

**Cars** > **Calendar sync**: a car listed on Turo or Getaround must never be booked twice.

1. Turo has no calendar link: Turo''s trip emails come in by themselves, find their car by themselves (Turo car number, plate, VIN, year, make, model, trim, colour, what earlier emails taught) and block it with the turnaround. Nothing to set up per car.
2. An email the reader cannot place waits as "Which car is this?": press **Which car is this?** and press the right car (best guesses first). It is remembered for that car''s next emails. If the dates or trip number are missing: **Add as a Turo trip** (choose the car, check the dates) or **Dismiss**. A trip whose email did not come: **Add a Turo trip** on the car.
3. Each Turo trip shows the guest''s name and phone when Turo''s email includes them. Contact a Turo guest only about their trip, never with promotions.
4. Turo cannot read our calendar: under "Block on Turo", block each CarmaCars booking on the car''s Turo calendar, then press **Done on Turo**. Dates that changed or a booking cancelled here show the dates to free on Turo.
5. Getaround, Google Calendar or another platform with a calendar (iCal) link: open **Add a calendar link**, choose the platform, paste it and press **Add the link**. Copy the car''s CarmaCars link for that platform with **Copy** and paste it into the platform''s calendar import.
6. A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.
', 'Fleet', 'Field jobs, daily checks, photo reviews, similar cars and listings.',
  'You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listing pipeline with its duplicate check and plate covering.

Your rail: Queue, Today, Field jobs, Field hours, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.

## Schedule field jobs

Every confirmed booking gets its handover (or delivery) and return (or pickup) jobs by itself, at the booking''s times and place, given to the field staff member with the fewest jobs that day. You check and change them.

1. Jobs, next three days: each with its place, its field staff and whether they acknowledged it. "Made from the booking" marks the ones made by themselves; when the booking moves, they move too, unless you changed them.
2. Change a job with **Assign**, **Reassign**, **Move** (time and place) or **Cancel**.
3. Handovers and returns without a job (when the automatic jobs are off, or one was cancelled) are listed first: press **Schedule**, the place filled in from the booking.
4. An Admin turns the automatic jobs or the assignment off in Settings > Program.

![](/guides/img/va-fleet-02-field-jobs-desktop-b985927b.jpg "desktop; size: 1230 1180; address: carmacars.ca/va/fleet; pins: 1 15.4 10.4, 2 78.9 12.7, 3 11.4 68.6, 4 78.9 83.9")

## Field hours

Field staff clock in and out on their phones. You see who is clocked in and every shift of the two-week pay period, and you fix what they cannot.

1. Open **Field hours**. **Clocked in now** lists who is on, since when. **Earlier period** and **Later period** move between pay periods.
2. Someone forgot to clock out: press **Clock out for them**, set the time they finished and write the reason.
3. Someone forgot to clock in, or a time is wrong: **Add hours** enters a shift, **Change** fixes one and **Remove** takes one out. Each needs a reason; the change is kept in a log with what it was before.
4. Once an Admin approves the pay run of a period, its shifts are locked: ask the Admin. You see hours only, not rates or pay.

## Daily checks

Twice a day: the opening check by 9:00 and the closing check by 18:00.

1. Open **Daily checks** and choose **Opening check** or **Closing check**.
2. Each line shows what was found. Tick OK, or Problem with a note.
3. Press **Save the opening check** (or **Save the closing check**). You can save it again.

![](/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg "desktop; size: 1230 820; address: carmacars.ca/va/checks; pins: 1 6.5 15.4, 2 44.7 42.0, 3 64.2 94.0")

## Check a car out or in

Fleet, Sales and Customer service check cars out and in from the booking.

1. On a confirmed booking press **Check out (pickup)**; on a booking on rent, **Check in (return)**. Today lists the ones due, each with its button.
2. The checklist field staff use opens: readings (km and fuel or charge), the photo set with the plate and the gauges, damage close-ups and both signatures.
3. Afterwards press **Photo report**: times, Late by, kilometres, fuel, photos and the return charges. Fleet waives a charge with **Waive** and a reason.

## Photo reviews after a return

After each return, the field photo set waits under **Photo reviews**. Compare it with the pickup set. Press **Review done**, or **Ask for a re-shoot** if a photo is missing or unclear.

## Similar cars

A possible duplicate never keeps a car off the site: it shows on the car''s checklist until you decide. Only Same car takes it off.

1. Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.
2. Compare the permit, the plate and the photos.
3. Press **Not a duplicate** with a note when they are different cars, or **Same car** when they are.

![](/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg "desktop; size: 1230 460; address: carmacars.ca/va/similar-cars; pins: 1 23.6 30.4, 3 94.8 30.4")

## Rates and kilometres

From a listing, press **The car and its rates**, or open the car from Field jobs.

1. Type the rates an Admin set. Only the daily rate is needed; the others follow from it when empty. The weekend rate is a price per day for each day that starts on a Friday or Saturday.
2. Keep **Use the defaults** for the kilometres, or choose **Custom for this car**.
3. Check What renters pay under the fields, then press **Save the rates**. Rates, kilometres and deposit save together.

## Listings and covering plates

1. Open **Listings**. A draft waiting shows Needs review. Open it.
2. The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.

![](/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg "desktop; size: 1230 340; address: carmacars.ca/va/listings; pins: 1 54.5 49.1")

3. Press **Cover the plate**. Check the suggested box; **Suggest the plate** asks again.
4. Drag over a plate to draw a box; drag a box to move it, its corner to resize it.
5. Choose **A CarmaCars plate**, **Pixelation** or **Blur**, then **Save the covered photo**.
6. No plate in the shot? **No plate visible on this photo**.

![](/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg "phone; size: 390 776; pins: 3 52.6 78.9, 4 50.0 43.8, 5 61.5 62.1, 6 43.1 92.3")

> Watch out: The plate check never holds a car back: a photo whose plate is not checked stays private, and goes public by itself once it is covered or marked. The covered photo replaces the public one; the original is kept privately.

## Publish now

Customer service and fleet publish a car themselves; nothing has to be finished first.

1. Open the car from Listings or Field jobs. Its listing says why it is not on the site yet; press **Publish now**. With no rates yet it uses the suggested rates (similar cars, else the class defaults).
2. What is still open (paperwork, details, photos, No VIN yet for a car added by its plate, a possible duplicate) shows as warnings after Publish now and on the car. None of them stops publishing.
3. New cars with their rates usually go on the site by themselves (Publish new cars automatically, on by default). A car taken off the site by staff waits for Publish now.

> Tip: A car not on the fleet insurance policy yet can be requested, offered and paid for, but never handed over until the insurer confirms it. Requests and offers for such a car show a warning.

## Calendar sync with Turo and other platforms

**Cars** > **Calendar sync**: a car listed on Turo or Getaround must never be booked twice.

1. Turo has no calendar link: Turo''s trip emails come in by themselves, find their car by themselves (Turo car number, plate, VIN, year, make, model, trim, colour, what earlier emails taught) and block it with the turnaround. Nothing to set up per car.
2. An email the reader cannot place waits as "Which car is this?": press **Which car is this?** and press the right car (best guesses first). It is remembered for that car''s next emails. If the dates or trip number are missing: **Add as a Turo trip** (choose the car, check the dates) or **Dismiss**. A trip whose email did not come: **Add a Turo trip** on the car.
3. Each Turo trip shows the guest''s name and phone when Turo''s email includes them. Contact a Turo guest only about their trip, never with promotions.
4. Turo cannot read our calendar: under "Block on Turo", block each CarmaCars booking on the car''s Turo calendar, then press **Done on Turo**. Dates that changed or a booking cancelled here show the dates to free on Turo.
5. Getaround, Google Calendar or another platform with a calendar (iCal) link: open **Add a calendar link**, choose the platform, paste it and press **Add the link**. Copy the car''s CarmaCars link for that platform with **Copy** and paste it into the platform''s calendar import.
6. A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.
',
  '<p class="gd-p">You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listing pipeline with its duplicate check and plate covering.</p><p class="gd-p">Your rail: Queue, Today, Field jobs, Field hours, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter and Scorecard.</p><section class="gd-task" id="fleet-schedule-field-jobs" data-gd-task><h2 class="gd-h2">Schedule field jobs</h2><p class="gd-p">Every confirmed booking gets its handover (or delivery) and return (or pickup) jobs by itself, at the booking&#39;s times and place, given to the field staff member with the fewest jobs that day. You check and change them.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Jobs, next three days: each with its place, its field staff and whether they acknowledged it. &quot;Made from the booking&quot; marks the ones made by themselves; when the booking moves, they move too, unless you changed them.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Change a job with <b class="gd-ui">Assign</b>, <b class="gd-ui">Reassign</b>, <b class="gd-ui">Move</b> (time and place) or <b class="gd-ui">Cancel</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Handovers and returns without a job (when the automatic jobs are off, or one was cancelled) are listed first: press <b class="gd-ui">Schedule</b>, the place filled in from the booking.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">An Admin turns the automatic jobs or the assignment off in Settings &gt; Program.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/fleet</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/1180"><img src="/guides/img/va-fleet-02-field-jobs-desktop-b985927b.jpg" alt="" loading="lazy" decoding="async" width="1230" height="1180"><span class="gd-pin" style="left:15.4%;top:10.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:78.9%;top:12.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:11.4%;top:68.6%" aria-hidden="true">3</span><span class="gd-pin" style="left:78.9%;top:83.9%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="fleet-field-hours" data-gd-task><h2 class="gd-h2">Field hours</h2><p class="gd-p">Field staff clock in and out on their phones. You see who is clocked in and every shift of the two-week pay period, and you fix what they cannot.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Field hours</b>. <b class="gd-ui">Clocked in now</b> lists who is on, since when. <b class="gd-ui">Earlier period</b> and <b class="gd-ui">Later period</b> move between pay periods.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Someone forgot to clock out: press <b class="gd-ui">Clock out for them</b>, set the time they finished and write the reason.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Someone forgot to clock in, or a time is wrong: <b class="gd-ui">Add hours</b> enters a shift, <b class="gd-ui">Change</b> fixes one and <b class="gd-ui">Remove</b> takes one out. Each needs a reason; the change is kept in a log with what it was before.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Once an Admin approves the pay run of a period, its shifts are locked: ask the Admin. You see hours only, not rates or pay.</div></li></ol></div></section><section class="gd-task" id="fleet-daily-checks" data-gd-task><h2 class="gd-h2">Daily checks</h2><p class="gd-p">Twice a day: the opening check by 9:00 and the closing check by 18:00.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Daily checks</b> and choose <b class="gd-ui">Opening check</b> or <b class="gd-ui">Closing check</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each line shows what was found. Tick OK, or Problem with a note.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save the opening check</b> (or <b class="gd-ui">Save the closing check</b>). You can save it again.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/checks</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/820"><img src="/guides/img/va-fleet-03-daily-checks-desktop-be06d6c0.jpg" alt="" loading="lazy" decoding="async" width="1230" height="820"><span class="gd-pin" style="left:6.5%;top:15.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:44.7%;top:42%" aria-hidden="true">2</span><span class="gd-pin" style="left:64.2%;top:94%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-check-a-car-out-or-in" data-gd-task><h2 class="gd-h2">Check a car out or in</h2><p class="gd-p">Fleet, Sales and Customer service check cars out and in from the booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On a confirmed booking press <b class="gd-ui">Check out (pickup)</b>; on a booking on rent, <b class="gd-ui">Check in (return)</b>. Today lists the ones due, each with its button.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The checklist field staff use opens: readings (km and fuel or charge), the photo set with the plate and the gauges, damage close-ups and both signatures.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Afterwards press <b class="gd-ui">Photo report</b>: times, Late by, kilometres, fuel, photos and the return charges. Fleet waives a charge with <b class="gd-ui">Waive</b> and a reason.</div></li></ol></div></section><section class="gd-task" id="fleet-photo-reviews-after-a-return" data-gd-task><h2 class="gd-h2">Photo reviews after a return</h2><p class="gd-p">After each return, the field photo set waits under <b class="gd-ui">Photo reviews</b>. Compare it with the pickup set. Press <b class="gd-ui">Review done</b>, or <b class="gd-ui">Ask for a re-shoot</b> if a photo is missing or unclear.</p></section><section class="gd-task" id="fleet-similar-cars" data-gd-task><h2 class="gd-h2">Similar cars</h2><p class="gd-p">A possible duplicate never keeps a car off the site: it shows on the car&#39;s checklist until you decide. Only Same car takes it off.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Compare the permit, the plate and the photos.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Not a duplicate</b> with a note when they are different cars, or <b class="gd-ui">Same car</b> when they are.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/similar-cars</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/460"><img src="/guides/img/va-fleet-06-similar-cars-desktop-562b0382.jpg" alt="" loading="lazy" decoding="async" width="1230" height="460"><span class="gd-pin" style="left:23.6%;top:30.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.8%;top:30.4%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fleet-rates-and-kilometres" data-gd-task><h2 class="gd-h2">Rates and kilometres</h2><p class="gd-p">From a listing, press <b class="gd-ui">The car and its rates</b>, or open the car from Field jobs.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type the rates an Admin set. Only the daily rate is needed; the others follow from it when empty. The weekend rate is a price per day for each day that starts on a Friday or Saturday.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Keep <b class="gd-ui">Use the defaults</b> for the kilometres, or choose <b class="gd-ui">Custom for this car</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check What renters pay under the fields, then press <b class="gd-ui">Save the rates</b>. Rates, kilometres and deposit save together.</div></li></ol></div></section><section class="gd-task" id="fleet-listings-and-covering-plates" data-gd-task><h2 class="gd-h2">Listings and covering plates</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Listings</b>. A draft waiting shows Needs review. Open it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/listings</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/340"><img src="/guides/img/va-fleet-05-listings-desktop-d2672e0a.jpg" alt="" loading="lazy" decoding="async" width="1230" height="340"><span class="gd-pin" style="left:54.5%;top:49.1%" aria-hidden="true">1</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Cover the plate</b>. Check the suggested box; <b class="gd-ui">Suggest the plate</b> asks again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Drag over a plate to draw a box; drag a box to move it, its corner to resize it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Choose <b class="gd-ui">A CarmaCars plate</b>, <b class="gd-ui">Pixelation</b> or <b class="gd-ui">Blur</b>, then <b class="gd-ui">Save the covered photo</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">No plate in the shot? <b class="gd-ui">No plate visible on this photo</b>.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/776"><img src="/guides/img/admin-11-plate-editor-phone-95d5afd2.jpg" alt="" loading="lazy" decoding="async" width="390" height="776"><span class="gd-pin" style="left:52.6%;top:78.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:50%;top:43.8%" aria-hidden="true">4</span><span class="gd-pin" style="left:61.5%;top:62.1%" aria-hidden="true">5</span><span class="gd-pin" style="left:43.1%;top:92.3%" aria-hidden="true">6</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>The plate check never holds a car back: a photo whose plate is not checked stays private, and goes public by itself once it is covered or marked. The covered photo replaces the public one; the original is kept privately.</div></aside></section><section class="gd-task" id="fleet-publish-now" data-gd-task><h2 class="gd-h2">Publish now</h2><p class="gd-p">Customer service and fleet publish a car themselves; nothing has to be finished first.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the car from Listings or Field jobs. Its listing says why it is not on the site yet; press <b class="gd-ui">Publish now</b>. With no rates yet it uses the suggested rates (similar cars, else the class defaults).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">What is still open (paperwork, details, photos, No VIN yet for a car added by its plate, a possible duplicate) shows as warnings after Publish now and on the car. None of them stops publishing.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">New cars with their rates usually go on the site by themselves (Publish new cars automatically, on by default). A car taken off the site by staff waits for Publish now.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A car not on the fleet insurance policy yet can be requested, offered and paid for, but never handed over until the insurer confirms it. Requests and offers for such a car show a warning.</div></aside></section><section class="gd-task" id="fleet-calendar-sync-with-turo-and-other-platforms" data-gd-task><h2 class="gd-h2">Calendar sync with Turo and other platforms</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Calendar sync</b>: a car listed on Turo or Getaround must never be booked twice.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Turo has no calendar link: Turo&#39;s trip emails come in by themselves, find their car by themselves (Turo car number, plate, VIN, year, make, model, trim, colour, what earlier emails taught) and block it with the turnaround. Nothing to set up per car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">An email the reader cannot place waits as &quot;Which car is this?&quot;: press <b class="gd-ui">Which car is this?</b> and press the right car (best guesses first). It is remembered for that car&#39;s next emails. If the dates or trip number are missing: <b class="gd-ui">Add as a Turo trip</b> (choose the car, check the dates) or <b class="gd-ui">Dismiss</b>. A trip whose email did not come: <b class="gd-ui">Add a Turo trip</b> on the car.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each Turo trip shows the guest&#39;s name and phone when Turo&#39;s email includes them. Contact a Turo guest only about their trip, never with promotions.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Turo cannot read our calendar: under &quot;Block on Turo&quot;, block each CarmaCars booking on the car&#39;s Turo calendar, then press <b class="gd-ui">Done on Turo</b>. Dates that changed or a booking cancelled here show the dates to free on Turo.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Getaround, Google Calendar or another platform with a calendar (iCal) link: open <b class="gd-ui">Add a calendar link</b>, choose the platform, paste it and press <b class="gd-ui">Add the link</b>. Copy the car&#39;s CarmaCars link for that platform with <b class="gd-ui">Copy</b> and paste it into the platform&#39;s calendar import.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.</div></li></ol></div></section>');
select app.guide_release_section('va', 'quick-reference', 'reference', 'shared-tools', '### Where things are

| Item | What it is for |
| --- | --- |
| **To do** | Next up, your lanes with their timers, then every open task |
| **Today at a glance** | Pickups, returns, what is due |
| **Working as** | Switch function (above the menu) |
| **Customer service** | Requests, New quote, Renter messages, Owner forms |
| **Finance** | Payments, Tolls and tickets, Reconciliation, Turo trips |
| **Fleet** | Field jobs, Daily checks, Photo reviews, Listings, Similar cars |
| **Sales** | Requests and offers, New quote, Add a rental, Owner leads |
| **Add a rental, New quote** | Every function |
| **My sales** | Your commissions, quotes, offers, bookings and booked revenue |
| **My scorecard** | Your results by week |

### Top tasks

1. *Take a task:* **My work** > **To do**, **Take it**, then **Done**
2. *Send an offer:* **Bookings** > **Requests**, the booking, then **Send the offer**
3. *Quote a caller:* **Bookings** > **New quote**, then **Create the request**
4. *See your sales:* **My work** > **My sales**, then **By week** or **By month**
5. *Claim a client you found:* **I sourced this client** when you add the rental or send the offer
6. *Review Forms C and D:* **Owner forms** > **Approve**
7. *Read a toll notice:* **Tolls and tickets** > **Read a notice**
8. *Issue a refund:* **Request the refund**, **Issue the refund**
9. *Schedule a field job:* **Field jobs** > **Schedule**
10. *Cover a plate:* **Cover the plate**, **Save the covered photo**

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **A task is above your limit** | Press **Escalate** and say why. An Admin picks it up. |
| **Asked for a 6-digit code** | Open your authenticator app. Lost your phone? Tell an Admin. |
', 'Quick reference', 'One page with the essentials.',
  '### Where things are

| Item | What it is for |
| --- | --- |
| **To do** | Next up, your lanes with their timers, then every open task |
| **Today at a glance** | Pickups, returns, what is due |
| **Working as** | Switch function (above the menu) |
| **Customer service** | Requests, New quote, Renter messages, Owner forms |
| **Finance** | Payments, Tolls and tickets, Reconciliation, Turo trips |
| **Fleet** | Field jobs, Field hours, Daily checks, Photo reviews, Listings, Similar cars |
| **Sales** | Requests and offers, New quote, Add a rental, Owner leads |
| **Add a rental, New quote** | Every function |
| **My sales** | Your commissions, quotes, offers, bookings and booked revenue |
| **My scorecard** | Your results by week |

### Top tasks

1. *Take a task:* **My work** > **To do**, **Take it**, then **Done**
2. *Send an offer:* **Bookings** > **Requests**, the booking, then **Send the offer**
3. *Quote a caller:* **Bookings** > **New quote**, then **Create the request**
4. *See your sales:* **My work** > **My sales**, then **By week** or **By month**
5. *Claim a client you found:* **I sourced this client** when you add the rental or send the offer
6. *Review Forms C and D:* **Owner forms** > **Approve**
7. *Read a toll notice:* **Tolls and tickets** > **Read a notice**
8. *Issue a refund:* **Request the refund**, **Issue the refund**
9. *Schedule a field job:* **Field jobs** > **Schedule**
10. *Cover a plate:* **Cover the plate**, **Save the covered photo**

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **A task is above your limit** | Press **Escalate** and say why. An Admin picks it up. |
| **Asked for a 6-digit code** | Open your authenticator app. Lost your phone? Tell an Admin. |
',
  '<h3 class="gd-h3">Where things are</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Item</th><th scope="col">What it is for</th></tr></thead><tbody><tr><td><b class="gd-ui">To do</b></td><td>Next up, your lanes with their timers, then every open task</td></tr><tr><td><b class="gd-ui">Today at a glance</b></td><td>Pickups, returns, what is due</td></tr><tr><td><b class="gd-ui">Working as</b></td><td>Switch function (above the menu)</td></tr><tr><td><b class="gd-ui">Customer service</b></td><td>Requests, New quote, Renter messages, Owner forms</td></tr><tr><td><b class="gd-ui">Finance</b></td><td>Payments, Tolls and tickets, Reconciliation, Turo trips</td></tr><tr><td><b class="gd-ui">Fleet</b></td><td>Field jobs, Field hours, Daily checks, Photo reviews, Listings, Similar cars</td></tr><tr><td><b class="gd-ui">Sales</b></td><td>Requests and offers, New quote, Add a rental, Owner leads</td></tr><tr><td><b class="gd-ui">Add a rental, New quote</b></td><td>Every function</td></tr><tr><td><b class="gd-ui">My sales</b></td><td>Your commissions, quotes, offers, bookings and booked revenue</td></tr><tr><td><b class="gd-ui">My scorecard</b></td><td>Your results by week</td></tr></tbody></table></div><h3 class="gd-h3">Top tasks</h3><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><em>Take a task:</em> <b class="gd-ui">My work</b> &gt; <b class="gd-ui">To do</b>, <b class="gd-ui">Take it</b>, then <b class="gd-ui">Done</b></div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><em>Send an offer:</em> <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Requests</b>, the booking, then <b class="gd-ui">Send the offer</b></div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><em>Quote a caller:</em> <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">New quote</b>, then <b class="gd-ui">Create the request</b></div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><em>See your sales:</em> <b class="gd-ui">My work</b> &gt; <b class="gd-ui">My sales</b>, then <b class="gd-ui">By week</b> or <b class="gd-ui">By month</b></div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><em>Claim a client you found:</em> <b class="gd-ui">I sourced this client</b> when you add the rental or send the offer</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><em>Review Forms C and D:</em> <b class="gd-ui">Owner forms</b> &gt; <b class="gd-ui">Approve</b></div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><em>Read a toll notice:</em> <b class="gd-ui">Tolls and tickets</b> &gt; <b class="gd-ui">Read a notice</b></div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t"><em>Issue a refund:</em> <b class="gd-ui">Request the refund</b>, <b class="gd-ui">Issue the refund</b></div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t"><em>Schedule a field job:</em> <b class="gd-ui">Field jobs</b> &gt; <b class="gd-ui">Schedule</b></div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t"><em>Cover a plate:</em> <b class="gd-ui">Cover the plate</b>, <b class="gd-ui">Save the covered photo</b></div></li></ol></div><h3 class="gd-h3">If something goes wrong</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">What you see</th><th scope="col">What to do</th></tr></thead><tbody><tr><td><b class="gd-ui">A link says it expired</b></td><td>Links in our emails work for 24 hours, once. Press <b class="gd-ui">Send me a new link</b> on that page.</td></tr><tr><td><b class="gd-ui">&quot;Error 1102&quot; on a page</b></td><td>A short limit on our web host. Reload the page. You are still signed in.</td></tr><tr><td><b class="gd-ui">&quot;That email and password do not match an account.&quot;</b></td><td>Check the address, or use <b class="gd-ui">Set a new password</b> on the sign-in page.</td></tr><tr><td><b class="gd-ui">A task is above your limit</b></td><td>Press <b class="gd-ui">Escalate</b> and say why. An Admin picks it up.</td></tr><tr><td><b class="gd-ui">Asked for a 6-digit code</b></td><td>Open your authenticator app. Lost your phone? Tell an Admin.</td></tr></tbody></table></div>');
select app.guide_release_section('field', 'my-jobs', 'chapter', 'start-here', 'Your day, in order: handovers, returns, deliveries, moves and photo shoots. Each job card has the car, the plate, the place and the time.

## Your job list

1. The menu: **My jobs**, **Report a problem**, **Add a rental**, **My sales**, **Referrals** and **Profile**. **Sign out** is top right.
2. Switch between **Today** and **Tomorrow**. Jobs are in time order.
3. The next job is the big card at the top: its time and how long until it, the car and its plate, the place with **Open in maps** and a button to call the renter, and what to put in the car. The rest of the day follows in time order.
4. A handover or a return has its own button: **Check out (pickup)** or **Check in (return)**. One tap acknowledges and starts the job and opens its photo checklist. Other jobs: press **Open the job**.
5. Moving a car that has no job? Use Vehicle moves (see below).

![](/guides/img/field-01-today-phone-421eca90.jpg "phone; size: 390 945; pins: 1 7.7 19.6, 2 76.9 27.5, 3 89.7 37.0, 4 88.5 46.6, 5 76.9 56.3")

> Tip: Need help on a job? Call CarmaCars at 289-312-5991. The link is at the bottom of My jobs.

## Open a job

1. The card shows the kind, the time, the car, the plate and colour.
2. The address, with **Open in maps** for directions, and a button to call the renter.
3. For a handover: the booking, the renter''s name and phone, the Card on File and the licence on file.
4. Press **Acknowledge** so the office knows you have it. Then press **Start** when you are with the car.

![](/guides/img/field-02-job-phone-a0feec93.jpg "phone; size: 390 635; pins: 1 94.9 51.2, 2 94.9 64.3, 3 94.9 79.5, 4 94.9 93.9")

## Move a car

1. Under Vehicle moves, press **Start a move**. Choose the Car and Why (for example Reposition).
2. Fill in From and the Odometer (km), then press **Start the move now**.
3. When you arrive, press **End the move**, fill in Now at and the odometer, then press **End the move now**.

![](/guides/img/field-01-today-phone-27dfe7af.jpg "phone; size: 390 450; pins: 1 87.2 22.2, 2 87.2 60.4, 3 87.2 93.3")

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. My jobs shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, wage and start date), then press **Read the PDF** and read it.
3. Press **Sign**. Your full legal name is your signature (or press **Draw instead**).
', 'My jobs', 'Your job list, a job card, maps and car moves.',
  'Your day, in order: handovers, returns, deliveries, moves and photo shoots. Each job card has the car, the plate, the place and the time.

## Your job list

1. The menu: **My jobs**, **Report a problem**, **My hours**, **Add a rental**, **My sales**, **Referrals** and **Profile**. **Sign out** is top right.
2. Switch between **Today** and **Tomorrow**. Jobs are in time order.
3. The next job is the big card at the top: its time and how long until it, the car and its plate, the place with **Open in maps** and a button to call the renter, and what to put in the car. The rest of the day follows in time order.
4. A handover or a return has its own button: **Check out (pickup)** or **Check in (return)**. One tap acknowledges and starts the job and opens its photo checklist. Other jobs: press **Open the job**.
5. Moving a car that has no job? Use Vehicle moves (see below).

![](/guides/img/field-01-today-phone-421eca90.jpg "phone; size: 390 945; pins: 1 7.7 19.6, 2 76.9 27.5, 3 89.7 37.0, 4 88.5 46.6, 5 76.9 56.3")

> Tip: Need help on a job? Call CarmaCars at 289-312-5991. The link is at the bottom of My jobs.

## Open a job

1. The card shows the kind, the time, the car, the plate and colour.
2. The address, with **Open in maps** for directions, and a button to call the renter.
3. For a handover: the booking, the renter''s name and phone, the Card on File and the licence on file.
4. Press **Acknowledge** so the office knows you have it. Then press **Start** when you are with the car.

![](/guides/img/field-02-job-phone-a0feec93.jpg "phone; size: 390 635; pins: 1 94.9 51.2, 2 94.9 64.3, 3 94.9 79.5, 4 94.9 93.9")

## Move a car

1. Under Vehicle moves, press **Start a move**. Choose the Car and Why (for example Reposition).
2. Fill in From and the Odometer (km), then press **Start the move now**.
3. When you arrive, press **End the move**, fill in Now at and the odometer, then press **End the move now**.

![](/guides/img/field-01-today-phone-27dfe7af.jpg "phone; size: 390 450; pins: 1 87.2 22.2, 2 87.2 60.4, 3 87.2 93.3")

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. My jobs shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, wage and start date), then press **Read the PDF** and read it.
3. Press **Sign**. Your full legal name is your signature (or press **Draw instead**).
',
  '<p class="gd-p">Your day, in order: handovers, returns, deliveries, moves and photo shoots. Each job card has the car, the plate, the place and the time.</p><section class="gd-task" id="my-jobs-your-job-list" data-gd-task><h2 class="gd-h2">Your job list</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The menu: <b class="gd-ui">My jobs</b>, <b class="gd-ui">Report a problem</b>, <b class="gd-ui">My hours</b>, <b class="gd-ui">Add a rental</b>, <b class="gd-ui">My sales</b>, <b class="gd-ui">Referrals</b> and <b class="gd-ui">Profile</b>. <b class="gd-ui">Sign out</b> is top right.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Switch between <b class="gd-ui">Today</b> and <b class="gd-ui">Tomorrow</b>. Jobs are in time order.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The next job is the big card at the top: its time and how long until it, the car and its plate, the place with <b class="gd-ui">Open in maps</b> and a button to call the renter, and what to put in the car. The rest of the day follows in time order.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A handover or a return has its own button: <b class="gd-ui">Check out (pickup)</b> or <b class="gd-ui">Check in (return)</b>. One tap acknowledges and starts the job and opens its photo checklist. Other jobs: press <b class="gd-ui">Open the job</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Moving a car that has no job? Use Vehicle moves (see below).</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/945"><img src="/guides/img/field-01-today-phone-421eca90.jpg" alt="" loading="lazy" decoding="async" width="390" height="945"><span class="gd-pin" style="left:7.7%;top:19.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:76.9%;top:27.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:89.7%;top:37%" aria-hidden="true">3</span><span class="gd-pin" style="left:88.5%;top:46.6%" aria-hidden="true">4</span><span class="gd-pin" style="left:76.9%;top:56.3%" aria-hidden="true">5</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Need help on a job? Call CarmaCars at 289-312-5991. The link is at the bottom of My jobs.</div></aside></section><section class="gd-task" id="my-jobs-open-a-job" data-gd-task><h2 class="gd-h2">Open a job</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The card shows the kind, the time, the car, the plate and colour.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The address, with <b class="gd-ui">Open in maps</b> for directions, and a button to call the renter.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">For a handover: the booking, the renter&#39;s name and phone, the Card on File and the licence on file.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Acknowledge</b> so the office knows you have it. Then press <b class="gd-ui">Start</b> when you are with the car.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/635"><img src="/guides/img/field-02-job-phone-a0feec93.jpg" alt="" loading="lazy" decoding="async" width="390" height="635"><span class="gd-pin" style="left:94.9%;top:51.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.9%;top:64.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:94.9%;top:79.5%" aria-hidden="true">3</span><span class="gd-pin" style="left:94.9%;top:93.9%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="my-jobs-move-a-car" data-gd-task><h2 class="gd-h2">Move a car</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Under Vehicle moves, press <b class="gd-ui">Start a move</b>. Choose the Car and Why (for example Reposition).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Fill in From and the Odometer (km), then press <b class="gd-ui">Start the move now</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">When you arrive, press <b class="gd-ui">End the move</b>, fill in Now at and the odometer, then press <b class="gd-ui">End the move now</b>.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/450"><img src="/guides/img/field-01-today-phone-27dfe7af.jpg" alt="" loading="lazy" decoding="async" width="390" height="450"><span class="gd-pin" style="left:87.2%;top:22.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:87.2%;top:60.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:87.2%;top:93.3%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="my-jobs-documents-to-sign" data-gd-task><h2 class="gd-h2">Documents to sign</h2><p class="gd-p">Your staff agreement, when CarmaCars sends it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">My jobs shows &quot;You have a document to sign&quot;. Press <b class="gd-ui">Read and sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the key values at the top (your role, wage and start date), then press <b class="gd-ui">Read the PDF</b> and read it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Sign</b>. Your full legal name is your signature (or press <b class="gd-ui">Draw instead</b>).</div></li></ol></div></section>');
select app.guide_release_section('field', 'my-hours-and-pay', 'chapter', 'photo-shoots', null, 'My hours and pay', 'Clock in and out, your hours, and your pay statements.',
  'Clock in when you start and out when you finish. Your hours are paid every two weeks at your hourly rate (CA$18.00 an hour unless your agreement says another rate), with the commissions an Admin has approved, and you get a pay statement for each pay.

## Clock in and out

1. Open **My hours**. When you start work, add a note if you like (for example where you start) and press **Clock in**.
2. The big clock shows how long you have been on. The jobs you finish while clocked in are listed under it.
3. When you finish, press **Clock out**. Add a note if you like. Your shift is saved with the time of each press.
4. Under **Recent shifts** you see the last three weeks, each with its jobs. **This pay period so far** shows your hours and what they come to at your rate.

> Watch out: Forgot to clock out, or a time is wrong? You cannot change it yourself. Tell Fleet: they fix it, say why, and the change is written in a log. A shift left running more than 16 hours has to be fixed by Fleet or an Admin.

## Your pay and your pay statements

A pay period is two weeks, Sunday to Saturday. An Admin runs the pay after it ends.

1. The pay is your hours times your hourly rate, plus the commissions and referral fees an Admin approved by the end of the period (see Commissions). Overtime and vacation pay are added only if CarmaCars has switched them on.
2. An Admin approves the pay run, pays you (by e-Transfer, bank transfer or cash) and records it. You get an email with the amount and how you were paid.
3. Under **Pay statements** on **My hours**, press **PDF** for the statement of a period: your hours day by day, the amounts, the commissions in it and how it was paid.

> Tip: A pay statement shows no income tax, CPP or EI. They are not worked out in the portal: for your tax slips, ask CarmaCars or your accountant.
',
  '<p class="gd-p">Clock in when you start and out when you finish. Your hours are paid every two weeks at your hourly rate (CA$18.00 an hour unless your agreement says another rate), with the commissions an Admin has approved, and you get a pay statement for each pay.</p><section class="gd-task" id="my-hours-and-pay-clock-in-and-out" data-gd-task><h2 class="gd-h2">Clock in and out</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">My hours</b>. When you start work, add a note if you like (for example where you start) and press <b class="gd-ui">Clock in</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The big clock shows how long you have been on. The jobs you finish while clocked in are listed under it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">When you finish, press <b class="gd-ui">Clock out</b>. Add a note if you like. Your shift is saved with the time of each press.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Under <b class="gd-ui">Recent shifts</b> you see the last three weeks, each with its jobs. <b class="gd-ui">This pay period so far</b> shows your hours and what they come to at your rate.</div></li></ol></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Forgot to clock out, or a time is wrong? You cannot change it yourself. Tell Fleet: they fix it, say why, and the change is written in a log. A shift left running more than 16 hours has to be fixed by Fleet or an Admin.</div></aside></section><section class="gd-task" id="my-hours-and-pay-your-pay-and-your-pay-statements" data-gd-task><h2 class="gd-h2">Your pay and your pay statements</h2><p class="gd-p">A pay period is two weeks, Sunday to Saturday. An Admin runs the pay after it ends.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The pay is your hours times your hourly rate, plus the commissions and referral fees an Admin approved by the end of the period (see Commissions). Overtime and vacation pay are added only if CarmaCars has switched them on.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">An Admin approves the pay run, pays you (by e-Transfer, bank transfer or cash) and records it. You get an email with the amount and how you were paid.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Under <b class="gd-ui">Pay statements</b> on <b class="gd-ui">My hours</b>, press <b class="gd-ui">PDF</b> for the statement of a period: your hours day by day, the amounts, the commissions in it and how it was paid.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A pay statement shows no income tax, CPP or EI. They are not worked out in the portal: for your tax slips, ask CarmaCars or your accountant.</div></aside></section>');
select app.guide_release_section('field', 'quick-reference', 'reference', 'report-rentals-referrals-and-profile', '### Where things are

| Item | What it is for |
| --- | --- |
| **My jobs** | Today and Tomorrow, in order; Vehicle moves |
| **A job** | Open in maps, Acknowledge, Start |
| **Report a problem** | Damage, warning light, collision, ticket, lost property |
| **Add a rental** | A renter you found: a payment link or the saved card |
| **My sales** | Your rentals and commissions |
| **Referrals** | Your link and QR code |
| **Profile** | Phone, home address, two-step sign-in, password, Sign out |

### Top tasks

1. *Start a job:* **Open the job**, **Acknowledge**, **Start**
2. *Hand over a car:* Every step, then **Hand over the keys**
3. *Fix a red line:* The buttons under the line, then **Check again**
4. *Stop a handover:* **Stop: do not release the car**, call us
5. *Take a car back:* Every step, then **Complete the return**
6. *Shoot listing photos:* **Take photo**, then **Submit for listing**
7. *Move a car:* **Start a move**, then **End the move** and **End the move now**
8. *Report an incident:* **Report a problem** > **Send the report**
9. *Add a rental:* **Add a rental**, **I sourced this client**, **Add the rental**

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **A photo did not upload** | Check your signal, then press **Send again**. |
| **The renter does not match** | Do not hand over. Press Stop and call us. |
', 'Quick reference', 'One page with the essentials.',
  '### Where things are

| Item | What it is for |
| --- | --- |
| **My jobs** | Today and Tomorrow, in order; Vehicle moves |
| **A job** | Open in maps, Acknowledge, Start |
| **Report a problem** | Damage, warning light, collision, ticket, lost property |
| **My hours** | Clock in and out, your shifts, your pay statements |
| **Add a rental** | A renter you found: a payment link or the saved card |
| **My sales** | Your rentals and commissions |
| **Referrals** | Your link and QR code |
| **Profile** | Phone, home address, two-step sign-in, password, Sign out |

### Top tasks

1. *Start a job:* **Open the job**, **Acknowledge**, **Start**
2. *Hand over a car:* Every step, then **Hand over the keys**
3. *Fix a red line:* The buttons under the line, then **Check again**
4. *Stop a handover:* **Stop: do not release the car**, call us
5. *Take a car back:* Every step, then **Complete the return**
6. *Shoot listing photos:* **Take photo**, then **Submit for listing**
7. *Move a car:* **Start a move**, then **End the move** and **End the move now**
8. *Report an incident:* **Report a problem** > **Send the report**
9. *Start and end work:* **My hours** > **Clock in**, then **Clock out**
10. *Add a rental:* **Add a rental**, **I sourced this client**, **Add the rental**

### If something goes wrong

| What you see | What to do |
| --- | --- |
| **A link says it expired** | Links in our emails work for 24 hours, once. Press **Send me a new link** on that page. |
| **"Error 1102" on a page** | A short limit on our web host. Reload the page. You are still signed in. |
| **"That email and password do not match an account."** | Check the address, or use **Set a new password** on the sign-in page. |
| **A photo did not upload** | Check your signal, then press **Send again**. |
| **The renter does not match** | Do not hand over. Press Stop and call us. |
',
  '<h3 class="gd-h3">Where things are</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Item</th><th scope="col">What it is for</th></tr></thead><tbody><tr><td><b class="gd-ui">My jobs</b></td><td>Today and Tomorrow, in order; Vehicle moves</td></tr><tr><td><b class="gd-ui">A job</b></td><td>Open in maps, Acknowledge, Start</td></tr><tr><td><b class="gd-ui">Report a problem</b></td><td>Damage, warning light, collision, ticket, lost property</td></tr><tr><td><b class="gd-ui">My hours</b></td><td>Clock in and out, your shifts, your pay statements</td></tr><tr><td><b class="gd-ui">Add a rental</b></td><td>A renter you found: a payment link or the saved card</td></tr><tr><td><b class="gd-ui">My sales</b></td><td>Your rentals and commissions</td></tr><tr><td><b class="gd-ui">Referrals</b></td><td>Your link and QR code</td></tr><tr><td><b class="gd-ui">Profile</b></td><td>Phone, home address, two-step sign-in, password, Sign out</td></tr></tbody></table></div><h3 class="gd-h3">Top tasks</h3><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><em>Start a job:</em> <b class="gd-ui">Open the job</b>, <b class="gd-ui">Acknowledge</b>, <b class="gd-ui">Start</b></div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><em>Hand over a car:</em> Every step, then <b class="gd-ui">Hand over the keys</b></div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><em>Fix a red line:</em> The buttons under the line, then <b class="gd-ui">Check again</b></div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><em>Stop a handover:</em> <b class="gd-ui">Stop: do not release the car</b>, call us</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><em>Take a car back:</em> Every step, then <b class="gd-ui">Complete the return</b></div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><em>Shoot listing photos:</em> <b class="gd-ui">Take photo</b>, then <b class="gd-ui">Submit for listing</b></div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><em>Move a car:</em> <b class="gd-ui">Start a move</b>, then <b class="gd-ui">End the move</b> and <b class="gd-ui">End the move now</b></div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t"><em>Report an incident:</em> <b class="gd-ui">Report a problem</b> &gt; <b class="gd-ui">Send the report</b></div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t"><em>Start and end work:</em> <b class="gd-ui">My hours</b> &gt; <b class="gd-ui">Clock in</b>, then <b class="gd-ui">Clock out</b></div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t"><em>Add a rental:</em> <b class="gd-ui">Add a rental</b>, <b class="gd-ui">I sourced this client</b>, <b class="gd-ui">Add the rental</b></div></li></ol></div><h3 class="gd-h3">If something goes wrong</h3><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">What you see</th><th scope="col">What to do</th></tr></thead><tbody><tr><td><b class="gd-ui">A link says it expired</b></td><td>Links in our emails work for 24 hours, once. Press <b class="gd-ui">Send me a new link</b> on that page.</td></tr><tr><td><b class="gd-ui">&quot;Error 1102&quot; on a page</b></td><td>A short limit on our web host. Reload the page. You are still signed in.</td></tr><tr><td><b class="gd-ui">&quot;That email and password do not match an account.&quot;</b></td><td>Check the address, or use <b class="gd-ui">Set a new password</b> on the sign-in page.</td></tr><tr><td><b class="gd-ui">A photo did not upload</b></td><td>Check your signal, then press <b class="gd-ui">Send again</b>.</td></tr><tr><td><b class="gd-ui">The renter does not match</b></td><td>Do not hand over. Press Stop and call us.</td></tr></tbody></table></div>');
-- GUIDES 0165 END
