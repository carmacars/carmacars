-- 0930: the field staff portal's work (Release 35, part X; docs/changes/2026-11-08-r35-field-portal.md). No applied migration
-- is edited. The owner (queue items 7, 8, 9 and the onboarding prep): one ordered work list per work day, built from the data,
-- each car and time one card; one Add for money spent, a service record, photos and a problem; renter help on the spot.
--   1. The work list of a day (app.fx_today): every pickup and return of the person (their field jobs on that work day, with the
--      deliveries and collections), the onboarding prep tasks given to them, then the cars to clean (not cleaned in
--      field_clean_every_days days), the cars needing service or not roadworthy, and in spare time the cars without a full
--      listing photo set. A pickup card carries the booking's add-ons, each ticked as in the car (field_addon_ticks); the
--      handover is refused until each is ticked or an Admin overrides (the override check 'addons', 0770). Every pickup and
--      return has a clean check (tick and photo, vehicle_clean_checks) before the pickup and after the return.
--   2. Money spent (field_spends): gas, a wash, parts, parking, with the receipt photo, the car and the booking; Finance
--      approves (a company expense under the matching category) and marks it reimbursed; a To do for the person while the
--      receipt is missing.
--   3. A service or repair done (what, where, odometer, cost, invoice photo): recorded on the car through the maintenance
--      tracker (app.maint_record, 0089) with its bill made at once (the company expense or the owner's cost: the car expense
--      line), Fleet and Finance alerted with a To do each, and the money on Finance's list as above.
--   4. Clock out with must-dos still open: each needs a reason (field_clock_open_items); Fleet is alerted.
--   5. Fleet and Admin: each person's list of a day with its completion (ops_read field_work_lists).
--   6. Onboarding prep (field_prep_tasks): Fleet or an Admin gives a person the prep of a car being onboarded on a day they
--      hold a shift (safety certificate, maintenance, cleaning, listing photos, plates and permit, tracker); each item is
--      ticked with its uploads; done items mark the owner onboarding checklist (registry visit, tracker, photos).
--   7. Renter help: field staff find any booking by number, name or phone (searches logged) and collect payment or the
--      deposit with the existing tools (the database already allowed field staff to collect: app.card_collect_allowed).
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

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if (length(d) - length(replace(d, p_old, ''))) / length(p_old) <> 1 then raise exception '0930: the text to change was not found once in %', p_sig; end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ settings, categories, items, rules
alter table program_settings
  add column field_clean_every_days integer not null default 7 check (field_clean_every_days between 1 and 60),
  add column field_offer_alert_hours integer not null default 12 check (field_offer_alert_hours between 1 and 72),
  add column field_late_cancel_hours integer not null default 24 check (field_late_cancel_hours between 1 and 168);
comment on column program_settings.field_clean_every_days is 'A car not cleaned in this many days gets a cleaning task on the field work list (0930).';
comment on column program_settings.field_offer_alert_hours is 'A given-up field shift nobody claimed this many hours before it starts alerts Fleet and Admin (0931).';
comment on column program_settings.field_late_cancel_hours is 'A field shift given up less than this many hours before it starts is flagged on the person''s record (0931).';

insert into company_expense_categories (code, label, gl_account) values
  ('field_fuel', 'Fuel bought by field staff', '5100'),
  ('field_cleaning', 'Car wash and cleaning supplies', '5100'),
  ('field_parts', 'Car parts and supplies', '5100'),
  ('field_parking', 'Parking and transit for field work', '5200')
on conflict (code) do nothing;

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description) values
  ('field_spend_review', 'finance', 'Approve field staff spending', 'normal', 'none', null, 'Field staff spent money for the company (gas, a wash, parts, a service). Check the receipt, approve or refuse, then mark it reimbursed when paid back.'),
  ('field_receipt_missing', 'fleet', 'Add the receipt', 'normal', 'none', null, 'Money spent was recorded without the receipt photo. Add it from My shifts or the Add button.'),
  ('field_service_fleet', 'fleet', 'Service recorded by field staff', 'normal', 'none', null, 'Field staff recorded a service or repair on a car. Check the car''s Maintenance tab: the timers were reset.'),
  ('field_clock_open', 'fleet', 'Field work left open at clock out', 'high', 'none', null, 'A field person clocked out with must-dos still open and gave a reason for each. Cover or move them.'),
  ('field_prep_done', 'fleet', 'Onboarding prep finished', 'normal', 'none', null, 'A field person finished the onboarding prep of a car. Check the uploads and the onboarding checklist.')
on conflict (task_type) do nothing;

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  ('field_spend', 'Field staff spent money', 'Field work', '{admin,on_duty:finance}', 'normal', 'alerts', true, false, 'Money spent by field staff waits for approval (0930).', 150),
  ('field_service', 'Service recorded by field staff', 'Field work', '{admin,on_duty:fleet}', 'normal', 'alerts', true, false, 'A service or repair recorded on a car from the field portal (0930).', 151),
  ('field_car_update', 'Field update on a car needing service', 'Field work', '{admin,on_duty:fleet}', 'normal', 'alerts', true, false, 'Field staff took a car in, left it at the shop or sorted it (0930).', 152),
  ('field_clock_open', 'Clocked out with work open', 'Field work', '{admin,on_duty:fleet}', 'urgent', 'alerts', true, false, 'A field person clocked out with must-dos open; each has a reason (0930).', 153),
  ('field_prep', 'Onboarding prep given to you', 'Field work', '{assigned}', 'normal', 'alerts', true, false, 'Fleet or an Admin gave a field person the onboarding prep of a car (0930).', 154)
on conflict (rule) do nothing;

-- ================================================================ 1. tables
create table field_addon_ticks (
  id               uuid primary key default gen_random_uuid(),
  booking_addon_id uuid not null unique references booking_addons (id) on delete cascade,
  booking_id       uuid not null references bookings (id) on delete cascade,
  field_job_id     uuid references field_jobs (id),
  ticked_by        uuid not null references users (id),
  ticked_at        timestamptz not null default now()
);
comment on table field_addon_ticks is 'An add-on of a booking ticked as in the car before the pickup (0930). The field handover is refused until every add-on is ticked or an Admin overrides (check addons).';

create table vehicle_clean_checks (
  id                uuid primary key default gen_random_uuid(),
  vehicle_id        uuid not null references vehicles (id),
  booking_id        uuid references bookings (id),
  field_job_id      uuid references field_jobs (id),
  moment            text not null check (moment in ('before_pickup', 'after_return', 'routine')),
  clean             boolean not null default true,
  note              text check (length(note) <= 500),
  photo_document_id uuid references documents (id),
  checked_by        uuid not null references users (id),
  checked_at        timestamptz not null default now(),
  check (clean or nullif(btrim(coalesce(note, '')), '') is not null)
);
create index vehicle_clean_checks_vehicle on vehicle_clean_checks (vehicle_id, checked_at desc);
create index vehicle_clean_checks_booking on vehicle_clean_checks (booking_id, moment);
comment on table vehicle_clean_checks is 'A car checked clean (tick and photo) before a pickup, after a return, or as a routine cleaning task (0930). Not clean needs a note.';

create table field_car_updates (
  id         uuid primary key default gen_random_uuid(),
  vehicle_id uuid not null references vehicles (id),
  status     text not null check (status in ('taken_in', 'at_shop', 'waiting_parts', 'sorted', 'note')),
  note       text check (length(note) <= 500),
  created_by uuid not null references users (id),
  created_at timestamptz not null default now()
);
create index field_car_updates_vehicle on field_car_updates (vehicle_id, created_at desc);
comment on table field_car_updates is 'A field person''s status update on a car needing service or not roadworthy (0930): taken in, at the shop, waiting for parts, sorted, or a note. Fleet is alerted.';

create table field_prep_tasks (
  id           uuid primary key default gen_random_uuid(),
  vehicle_id   uuid not null references vehicles (id),
  staff_id     uuid not null references users (id),
  work_day     date not null,
  items        text[] not null check (cardinality(items) between 1 and 6
                 and items <@ array['safety_certificate', 'maintenance', 'cleaning', 'listing_photos', 'plates_permit', 'tracker']),
  done         jsonb not null default '{}'::jsonb check (jsonb_typeof(done) = 'object'),
  note         text check (length(note) <= 500),
  status       text not null default 'planned' check (status in ('planned', 'done', 'cancelled')),
  created_by   uuid not null references users (id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  completed_at timestamptz,
  cancelled_at timestamptz,
  cancelled_by uuid references users (id),
  check ((status = 'done') = (completed_at is not null)),
  check ((status = 'cancelled') = (cancelled_at is not null))
);
create index field_prep_tasks_staff on field_prep_tasks (staff_id, work_day) where status = 'planned';
create index field_prep_tasks_vehicle on field_prep_tasks (vehicle_id);
create trigger field_prep_tasks_updated before update on field_prep_tasks for each row execute function app.set_updated_at();
comment on table field_prep_tasks is 'Onboarding prep given to a field person for a day they hold a shift (0930): the items to do on a car being onboarded, each ticked in done {code: {at, by, note, documents}}; finishing marks the owner onboarding checklist (registry_visit, tracker_install, photos).';

create table field_spends (
  id                  uuid primary key default gen_random_uuid(),
  staff_id            uuid not null references users (id),
  kind                text not null check (kind in ('gas', 'wash', 'parts', 'parking', 'service', 'other')),
  spent_on            date not null,
  description         text not null check (length(btrim(description)) between 2 and 300),
  amount_cents        bigint not null check (amount_cents > 0),
  hst_cents           bigint not null default 0 check (hst_cents >= 0),
  vehicle_id          uuid references vehicles (id),
  booking_id          uuid references bookings (id),
  prep_task_id        uuid references field_prep_tasks (id),
  paid_with           text not null default 'own' check (paid_with in ('own', 'company')),
  receipt_document_id uuid references documents (id),
  service_record_id   uuid references vehicle_service_records (id),
  company_expense_id  uuid references company_expenses (id),
  status              text not null default 'submitted' check (status in ('submitted', 'approved', 'refused', 'reimbursed')),
  decided_by          uuid references users (id),
  decided_at          timestamptz,
  decision_note       text check (length(decision_note) <= 300),
  reimbursed_by       uuid references users (id),
  reimbursed_at       timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  check (status = 'submitted' or decided_at is not null),
  check ((status = 'reimbursed') = (reimbursed_at is not null))
);
create index field_spends_staff on field_spends (staff_id, spent_on desc);
create index field_spends_open on field_spends (status) where status in ('submitted', 'approved');
create trigger field_spends_updated before update on field_spends for each row execute function app.set_updated_at();
comment on table field_spends is 'Money a field person spent for the company (0930): the receipt, the car and the booking; Finance approves it (a company expense, or the service''s bill already made) and marks it reimbursed when paid with their own money.';

create table field_clock_open_items (
  id         uuid primary key default gen_random_uuid(),
  shift_id   uuid references field_shifts (id),
  staff_id   uuid not null references users (id),
  item_key   text not null check (length(item_key) <= 120),
  label      text not null check (length(label) <= 300),
  reason     text not null check (length(btrim(reason)) between 3 and 300),
  created_at timestamptz not null default now()
);
create index field_clock_open_items_staff on field_clock_open_items (staff_id, created_at desc);
comment on table field_clock_open_items is 'The must-dos still open when a field person clocked out, each with their reason (0930). Fleet is alerted and given a To do.';

do $$
declare t text;
begin
  foreach t in array array['field_addon_ticks', 'vehicle_clean_checks', 'field_car_updates', 'field_prep_tasks', 'field_spends', 'field_clock_open_items'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy admin_all on %I for all to authenticated using (app.is_admin()) with check (app.is_admin())', t);
    execute format('revoke all on %I from public, anon, authenticated', t);
    execute format('grant select on %I to authenticated', t);
    execute format('grant all on %I to service_role', t);
    execute format('create trigger audit_%s after insert or update or delete on %I for each row execute function app.audit_row()', t, t);
  end loop;
end $$;
create policy own_select on field_spends for select to authenticated using (staff_id = app.uid());
create policy own_select on field_prep_tasks for select to authenticated using (staff_id = app.uid());

-- ================================================================ 2. helpers
-- the work day of a job: its planned day (0880) or its own day
create function app.fx_job_day(j field_jobs) returns date
language sql stable as $$ select coalesce(j.work_day, app.local_date(j.scheduled_at)) $$;

create function app.fx_leg(p_kind text) returns text
language sql immutable as $$
  select case when p_kind in ('handover', 'delivery') then 'pickup' when p_kind in ('return_check_in', 'pickup_from_renter') then 'return' end
$$;

-- the add-ons of a booking that go in the car (not prepaid fuel, not an hourly service), with their tick
create function app.fx_addons(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', ba.id, 'name', ba.name, 'quantity', ba.quantity, 'note', a.handover_note,
           'ticked', t.id is not null, 'ticked_at', t.ticked_at, 'ticked_by', (select u.full_name from users u where u.id = t.ticked_by)) order by a.sort_order, ba.name), '[]'::jsonb)
    from booking_addons ba join addons a on a.id = ba.addon_id
    left join field_addon_ticks t on t.booking_addon_id = ba.id
   where ba.booking_id = p_booking and ba.status = 'confirmed' and not a.prepaid_fuel and ba.pricing_unit <> 'per_hour'
$$;

create function app.fx_addons_open(p_booking uuid) returns integer
language sql stable security definer set search_path = public, app as $$
  select count(*)::integer from booking_addons ba join addons a on a.id = ba.addon_id
   where ba.booking_id = p_booking and ba.status = 'confirmed' and not a.prepaid_fuel and ba.pricing_unit <> 'per_hour'
     and not exists (select 1 from field_addon_ticks t where t.booking_addon_id = ba.id)
$$;

create function app.fx_clean_done(p_booking uuid, p_moment text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from vehicle_clean_checks c where c.booking_id = p_booking and c.moment = p_moment)
$$;

-- a document from an upload made by the website (the private documents bucket): p {storage_path, mime_type, sha256, title}
create function app.fx_doc(p_by uuid, p jsonb, p_kind text, p_vehicle uuid, p_booking uuid default null, p_title text default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare v_id uuid;
begin
  if p is null or nullif(p ->> 'storage_path', '') is null then return null; end if;
  if (p ->> 'storage_path') !~ '^field/[0-9]{4}/[0-9a-f-]{36}\.(jpg|png|pdf)$' then raise exception 'The upload is not one of ours' using errcode = '22023'; end if;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, uploaded_by, vehicle_id, booking_id)
  values (p_kind::document_kind, left(coalesce(p_title, p ->> 'title', 'Field upload'), 200), 'documents', p ->> 'storage_path', p ->> 'mime_type', p ->> 'sha256', p_by, p_vehicle, p_booking)
  returning id into v_id;
  return v_id;
end $$;

-- the person has this booking on their list (a job of theirs that is not cancelled), or runs Fleet
create function app.fx_on_booking(p_user uuid, p_booking uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_runs_fleet(p_user) or exists (select 1 from field_jobs j where j.booking_id = p_booking and j.assigned_to = p_user and j.status <> 'cancelled')
$$;

-- a car the person may work on: one of their jobs or prep tasks of the last week or the next two, or any active car while they
-- hold a shift today (cleaning, service and photo cards are for everyone on shift)
create function app.fx_may_car(p_user uuid, p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_runs_fleet(p_user)
      or exists (select 1 from field_jobs j where j.vehicle_id = p_vehicle and j.assigned_to = p_user and j.status <> 'cancelled'
                   and j.scheduled_at between now() - interval '7 days' and now() + interval '14 days')
      or exists (select 1 from field_prep_tasks t where t.vehicle_id = p_vehicle and t.staff_id = p_user and t.status <> 'cancelled')
      or (exists (select 1 from vehicles v where v.id = p_vehicle and v.retired_at is null and not v.is_sample and v.status not in ('exited', 'declined', 'total_loss'))
          and (exists (select 1 from field_shift_plans s where s.staff_id = p_user and s.cancelled_at is null and app.local_date(s.starts_at) = app.today())
               or exists (select 1 from field_shifts f where f.staff_id = p_user and f.ended_at is null and f.voided_at is null)))
$$;

create function app.fx_prep_label(p_code text) returns text
language sql immutable as $$
  select case p_code when 'safety_certificate' then 'Get the safety certificate' when 'maintenance' then 'Do the maintenance and repairs it needs'
    when 'cleaning' then 'Clean the car' when 'listing_photos' then 'Take the listing photos' when 'plates_permit' then 'Pick up the plates and permit'
    when 'tracker' then 'Install the tracker' else replace(p_code, '_', ' ') end
$$;

-- ================================================================ 3. the work list of a day
create function app.fx_job_card(p_user uuid, j field_jobs) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  v vehicles;
  v_leg text := app.fx_leg(j.kind);
  v_addons jsonb := '[]'::jsonb;
  v_open integer := 0;
  v_clean boolean;
  v_blockers jsonb;
  v_moment text := case app.fx_leg(j.kind) when 'pickup' then 'before_pickup' when 'return' then 'after_return' end;
begin
  select * into v from vehicles where id = j.vehicle_id;
  if j.booking_id is not null then select * into b from bookings where id = j.booking_id; end if;
  if b.id is not null and v_leg = 'pickup' then v_addons := app.fx_addons(b.id); v_open := app.fx_addons_open(b.id); end if;
  v_clean := case when b.id is null or v_moment is null then null else app.fx_clean_done(b.id, v_moment) end;
  if b.id is not null and v_leg = 'pickup' and j.status <> 'done' and b.status in ('pending_payment', 'confirmed') then
    begin v_blockers := app.handover_blockers(p_user, b.id, 'pickup', '{}'::jsonb); exception when others then v_blockers := null; end;
  end if;
  return jsonb_build_object('type', 'job', 'key', 'job:' || j.id, 'id', j.id, 'kind', j.kind, 'leg', v_leg, 'status', j.status, 'at', j.scheduled_at,
    'place', j.place, 'instructions', j.instructions, 'must', true,
    'vehicle', jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate),
    'booking', case when b.id is not null then jsonb_build_object('id', b.id, 'number', b.booking_number, 'status', b.status,
      'renter', (select split_part(btrim(r.legal_name), ' ', 1) from renters r where r.id = b.renter_id),
      'mobile', (select r.mobile from renters r where r.id = b.renter_id)) end,
    'addons', v_addons, 'addons_open', v_open,
    'clean', case when v_moment is not null and b.id is not null then jsonb_build_object('moment', v_moment, 'done', v_clean) end,
    'blockers', coalesce(v_blockers, '[]'::jsonb),
    'done', j.status = 'done' and coalesce(v_clean, true) and v_open = 0);
end $$;

create function app.fx_today(p_user uuid, p_day date default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  d date := coalesce(p_day, app.today());
  s program_settings := app.settings();
  v_jobs jsonb;
  v_prep jsonb;
  v_clean jsonb := '[]'::jsonb;
  v_service jsonb := '[]'::jsonb;
  v_photos jsonb := '[]'::jsonb;
  v_on_shift boolean;
  v_job_cars uuid[];
begin
  select coalesce(jsonb_agg(app.fx_job_card(p_user, j) order by j.scheduled_at, j.id), '[]'::jsonb), coalesce(array_agg(distinct j.vehicle_id), '{}')
    into v_jobs, v_job_cars
    from field_jobs j where j.assigned_to = p_user and j.status <> 'cancelled' and app.fx_job_day(j) = d;
  -- a car with a card already (a job or prep today) gets no second card for cleaning or photos
  v_job_cars := v_job_cars || coalesce((select array_agg(t.vehicle_id) from field_prep_tasks t where t.staff_id = p_user and t.work_day = d and t.status <> 'cancelled'), '{}');
  select coalesce(jsonb_agg(jsonb_build_object('type', 'prep', 'key', 'prep:' || t.id, 'id', t.id, 'status', t.status, 'must', true,
           'at', (app.local_midnight(t.work_day) + interval '9 hours'), 'note', t.note,
           'vehicle', jsonb_build_object('id', t.vehicle_id, 'name', app.vehicle_name(t.vehicle_id), 'plate', (select v.plate from vehicles v where v.id = t.vehicle_id)),
           'items', (select jsonb_agg(jsonb_build_object('code', c, 'label', app.fx_prep_label(c), 'done', t.done ? c, 'at', t.done -> c ->> 'at', 'note', t.done -> c ->> 'note')) from unnest(t.items) c),
           'done', t.status = 'done') order by t.created_at), '[]'::jsonb)
    into v_prep from field_prep_tasks t where t.staff_id = p_user and t.work_day = d and t.status <> 'cancelled';
  v_on_shift := exists (select 1 from field_shift_plans x where x.staff_id = p_user and x.cancelled_at is null and app.local_date(x.starts_at) = d)
                or (d = app.today() and exists (select 1 from field_shifts f where f.staff_id = p_user and f.ended_at is null and f.voided_at is null));
  if v_on_shift and d = app.today() then
    -- c) cars not cleaned in N days (at the lot: not on rent), oldest first
    select coalesce(jsonb_agg(x.o order by x.last nulls first, x.fleet_number nulls last), '[]'::jsonb) into v_clean from (
      select v.fleet_number, jsonb_build_object('type', 'clean', 'key', 'clean:' || v.id, 'must', false, 'done', false,
               'vehicle', jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate),
               'last', c.last, 'days', case when c.last is not null then (app.today() - app.local_date(c.last)) end) as o, c.last
        from vehicles v left join lateral (select max(k.checked_at) as last from vehicle_clean_checks k where k.vehicle_id = v.id and k.clean) c on true
       where v.status in ('available', 'ready_to_list', 'cleaning') and v.retired_at is null and not v.is_sample and v.id <> all (v_job_cars)
         and (c.last is null or c.last < now() - make_interval(days => s.field_clean_every_days))
       order by c.last nulls first, v.fleet_number nulls last limit 4) x;
    -- d) cars needing service or not roadworthy
    select coalesce(jsonb_agg(x.o), '[]'::jsonb) into v_service from (
      select jsonb_build_object('type', 'service', 'key', 'service:' || v.id, 'must', false, 'done', false,
               'vehicle', jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate),
               'why', concat_ws('; ', case when v.status = 'out_of_service' then 'Out of service' end, app.maint_handover_block(v.id),
                 (select 'Overdue: ' || string_agg(i.label, ', ' order by i.sort_order) from vehicle_service_items vi join service_items i on i.code = vi.item_code
                   where vi.vehicle_id = v.id and vi.status = 'overdue')),
               'update', (select jsonb_build_object('status', u.status, 'note', u.note, 'at', u.created_at, 'by', (select us.full_name from users us where us.id = u.created_by))
                            from field_car_updates u where u.vehicle_id = v.id order by u.created_at desc limit 1)) as o
        from vehicles v
       where v.retired_at is null and not v.is_sample and v.status not in ('exited', 'declined', 'total_loss', 'onboarding')
         and (v.status = 'out_of_service' or app.maint_handover_block(v.id) is not null
              or exists (select 1 from vehicle_service_items vi where vi.vehicle_id = v.id and vi.status = 'overdue'))
         and not exists (select 1 from field_car_updates u where u.vehicle_id = v.id and u.status = 'sorted' and u.created_at > now() - interval '3 days')
       order by v.status = 'out_of_service' desc, v.fleet_number nulls last limit 4) x;
    -- e) spare time: cars without a full listing photo set
    select coalesce(jsonb_agg(x.o), '[]'::jsonb) into v_photos from (
      select jsonb_build_object('type', 'photos', 'key', 'photos:' || v.id, 'must', false, 'done', false,
               'vehicle', jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate),
               'missing', to_jsonb(app.listing_photo_problems(v.id))) as o
        from vehicles v
       where v.retired_at is null and not v.is_sample and v.status in ('available', 'ready_to_list', 'onboarding')
         and v.id <> all (v_job_cars) and cardinality(app.listing_photo_problems(v.id)) > 0
       order by v.fleet_number nulls last limit 3) x;
  end if;
  return jsonb_build_object('day', d, 'on_shift', v_on_shift,
    'shift', (select jsonb_build_object('id', x.id, 'starts_at', x.starts_at, 'ends_at', x.ends_at, 'note', x.note) from field_shift_plans x
               where x.staff_id = p_user and x.cancelled_at is null and app.local_date(x.starts_at) = d order by x.starts_at limit 1),
    'clock', (select jsonb_build_object('id', f.id, 'started_at', f.started_at) from field_shifts f where f.staff_id = p_user and f.ended_at is null and f.voided_at is null limit 1),
    'cards', v_jobs || v_prep || v_clean || v_service || v_photos,
    'todo', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'title', t.title, 'detail', t.detail, 'type', t.task_type, 'related_id', t.related_id) order by t.created_at)
                        from tasks t where t.assigned_to = p_user and t.status in ('open', 'in_progress', 'waiting')
                          and t.task_type in ('field_receipt_missing', 'field_pay_details', 'first_day')), '[]'::jsonb),
    'counts', jsonb_build_object('must', jsonb_array_length(v_jobs) + jsonb_array_length(v_prep),
               'done', (select count(*) from jsonb_array_elements(v_jobs || v_prep) c where (c ->> 'done')::boolean)));
end $$;

-- the must-dos still open of a person's day: [{key, label}]
create function app.fx_open_musts(p_user uuid, p_day date default null) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('key', c ->> 'key', 'label',
           concat_ws(', ', case c ->> 'type' when 'prep' then 'Onboarding prep' else initcap(replace(coalesce(c ->> 'leg', c ->> 'kind'), '_', ' ')) end,
                     c #>> '{vehicle,name}', c #>> '{booking,number}',
                     case when c ->> 'type' = 'job' and c ->> 'status' = 'done' and (c #>> '{clean,done}') = 'false' then 'clean check missing' end,
                     case when (c ->> 'addons_open')::int > 0 then (c ->> 'addons_open') || ' add-on(s) not ticked' end))), '[]'::jsonb)
    from jsonb_array_elements(app.fx_today(p_user, p_day) -> 'cards') c
   where (c ->> 'must')::boolean and not (c ->> 'done')::boolean
$$;

-- ================================================================ 4. the steps
create function app.fx_addon_tick(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ba booking_addons;
  v_on boolean := coalesce((p ->> 'ticked')::boolean, true);
begin
  select * into ba from booking_addons where id = nullif(p ->> 'id', '')::uuid;
  if ba.id is null then raise exception 'That add-on is not on the booking' using errcode = 'P0002'; end if;
  if not app.fx_on_booking(p_user, ba.booking_id) then raise exception 'This booking is not on your list' using errcode = '42501'; end if;
  if exists (select 1 from bookings b where b.id = ba.booking_id and b.status not in ('pending_payment', 'confirmed')) and v_on is false then
    raise exception 'The car has left: the add-ons stay ticked' using errcode = '23514';
  end if;
  if v_on then
    insert into field_addon_ticks (booking_addon_id, booking_id, field_job_id, ticked_by)
    values (ba.id, ba.booking_id, (select j.id from field_jobs j where j.booking_id = ba.booking_id and j.assigned_to = p_user and j.status <> 'cancelled' and j.kind in ('handover', 'delivery') limit 1), p_user)
    on conflict (booking_addon_id) do nothing;
  else
    delete from field_addon_ticks where booking_addon_id = ba.id;
  end if;
  return jsonb_build_object('booking_id', ba.booking_id, 'open', app.fx_addons_open(ba.booking_id));
end $$;

-- p: vehicle, booking, job, moment, clean, note, photo {storage_path, mime_type, sha256}
create function app.fx_clean_check(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  j field_jobs;
  v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid;
  v_booking uuid;
  v_moment text := coalesce(nullif(p ->> 'moment', ''), 'routine');
  v_doc uuid;
  v_id uuid;
begin
  if nullif(p ->> 'job', '') is not null then
    select * into j from field_jobs where id = (p ->> 'job')::uuid and assigned_to = p_user and status <> 'cancelled';
    if j.id is null then raise exception 'That job is not one of yours' using errcode = '42501'; end if;
    v_vehicle := j.vehicle_id; v_booking := j.booking_id;
    v_moment := case app.fx_leg(j.kind) when 'pickup' then 'before_pickup' when 'return' then 'after_return' else 'routine' end;
  end if;
  if v_vehicle is null then raise exception 'Choose the car' using errcode = '22023'; end if;
  if v_moment not in ('before_pickup', 'after_return', 'routine') then raise exception 'Unknown moment' using errcode = '22023'; end if;
  if j.id is null and not app.fx_may_car(p_user, v_vehicle) then raise exception 'This car is not on your list today' using errcode = '42501'; end if;
  if coalesce(p -> 'photo' ->> 'storage_path', '') = '' then raise exception 'Take a photo of the clean car' using errcode = '22023'; end if;
  if not coalesce((p ->> 'clean')::boolean, true) and nullif(btrim(coalesce(p ->> 'note', '')), '') is null then
    raise exception 'Say what is not clean' using errcode = '22023';
  end if;
  v_doc := app.fx_doc(p_user, p -> 'photo', 'other', v_vehicle, v_booking, 'Clean check');
  insert into vehicle_clean_checks (vehicle_id, booking_id, field_job_id, moment, clean, note, photo_document_id, checked_by)
  values (v_vehicle, v_booking, j.id, v_moment, coalesce((p ->> 'clean')::boolean, true), nullif(btrim(coalesce(p ->> 'note', '')), ''), v_doc, p_user)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'moment', v_moment);
end $$;

-- p: vehicle, status, note
create function app.fx_car_update(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid;
  v_status text := coalesce(nullif(p ->> 'status', ''), 'note');
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  v_id uuid;
  v_name text;
begin
  if v_vehicle is null or not app.fx_may_car(p_user, v_vehicle) then raise exception 'This car is not on your list today' using errcode = '42501'; end if;
  if v_status not in ('taken_in', 'at_shop', 'waiting_parts', 'sorted', 'note') then raise exception 'Choose what happened' using errcode = '22023'; end if;
  if v_status in ('note', 'waiting_parts') and v_note is null then raise exception 'Write the update' using errcode = '22023'; end if;
  insert into field_car_updates (vehicle_id, status, note, created_by) values (v_vehicle, v_status, v_note, p_user) returning id into v_id;
  select full_name into v_name from users where id = p_user;
  perform app.staff_alert('field_car_update', 'field_car_update', v_id, v_status,
    format('%s: %s', app.vehicle_name(v_vehicle), case v_status when 'taken_in' then 'taken in for service' when 'at_shop' then 'left at the shop'
      when 'waiting_parts' then 'waiting for parts' when 'sorted' then 'sorted, back on the road' else 'an update' end),
    concat_ws('. ', coalesce(v_name, 'Field staff'), v_note), jsonb_build_object('path_admin', '/admin/vehicles/' || v_vehicle, 'path_staff', '/staff/vehicles/' || v_vehicle));
  return jsonb_build_object('id', v_id);
end $$;

-- the category of money spent
create function app.fx_spend_category(p_kind text) returns text
language sql immutable as $$
  select case p_kind when 'gas' then 'field_fuel' when 'wash' then 'field_cleaning' when 'parts' then 'field_parts' when 'parking' then 'field_parking'
    when 'service' then 'maint_service' else 'other' end
$$;

-- after a spend is recorded: Finance's To do and alert, and the person's own To do while the receipt is missing
create function app.fx_spend_after(p_id uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  x field_spends;
  v_name text;
  v_task uuid;
begin
  select * into x from field_spends where id = p_id;
  select full_name into v_name from users where id = x.staff_id;
  perform app.raise_task(p_type => 'field_spend_review', p_title => format('Approve %s spent by %s: %s', app.fmt_money(x.amount_cents + x.hst_cents), coalesce(v_name, 'field staff'), x.description),
    p_detail => format('%s on %s%s. %s', initcap(x.kind), app.maint_date_text(x.spent_on), coalesce(', ' || app.vehicle_name(x.vehicle_id), ''),
                       case when x.receipt_document_id is null then 'No receipt yet: they have a To do to add it.' else 'Receipt attached.' end),
    p_booking => x.booking_id, p_vehicle => x.vehicle_id, p_related_table => 'field_spends', p_related_id => x.id, p_queue => 'finance',
    p_dedupe => 'field_spend_review:' || x.id, p_created_by => x.staff_id);
  perform app.staff_alert('field_spend', 'field_spend', x.id, 'new', format('%s spent %s: %s', coalesce(v_name, 'Field staff'), app.fmt_money(x.amount_cents + x.hst_cents), x.description),
    case when x.receipt_document_id is null then 'No receipt yet.' else 'Receipt attached. Approve it on Field spending.' end,
    jsonb_build_object('path_admin', '/admin/money/field-pay?tab=spending', 'path_staff', '/staff/field-hours?tab=spending'));
  if x.receipt_document_id is null then
    v_task := app.raise_task(p_type => 'field_receipt_missing', p_title => format('Add the receipt (%s): %s, %s', coalesce(v_name, 'field staff'), x.description, app.fmt_money(x.amount_cents + x.hst_cents)),
      p_detail => 'Take a photo of the receipt: open it on Today (To do) or My shifts.', p_vehicle => x.vehicle_id, p_related_table => 'field_spends', p_related_id => x.id,
      p_queue => 'fleet', p_dedupe => 'field_receipt_missing:' || x.id, p_created_by => x.staff_id);
    if v_task is not null then update tasks set assigned_to = x.staff_id where id = v_task; end if;
  end if;
end $$;

-- p: kind, spent_on, description, amount_cents, hst_cents, vehicle, booking, prep, paid_with, receipt {..}
create function app.fx_spend_add(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_kind text := coalesce(nullif(p ->> 'kind', ''), 'other');
  v_on date := coalesce(nullif(p ->> 'spent_on', '')::date, app.today());
  v_amount bigint := nullif(p ->> 'amount_cents', '')::bigint;
  v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid;
  v_booking uuid := nullif(p ->> 'booking', '')::uuid;
  v_id uuid;
begin
  if v_kind not in ('gas', 'wash', 'parts', 'parking', 'other') then raise exception 'Choose what it was for' using errcode = '22023'; end if;
  if v_amount is null or v_amount <= 0 then raise exception 'Enter the amount' using errcode = '22023'; end if;
  if v_amount > 500000 then raise exception 'Over $5,000: ask Fleet to enter it' using errcode = '23514'; end if;
  if v_on > app.today() or v_on < app.today() - 60 then raise exception 'The date is within the last 60 days' using errcode = '22023'; end if;
  if length(btrim(coalesce(p ->> 'description', ''))) < 2 then raise exception 'Say what you bought' using errcode = '22023'; end if;
  if v_vehicle is not null and not app.fx_may_car(p_user, v_vehicle) then raise exception 'This car is not on your list' using errcode = '42501'; end if;
  if v_booking is not null and not exists (select 1 from bookings b where b.id = v_booking and (v_vehicle is null or b.vehicle_id = v_vehicle)) then
    raise exception 'That booking is not this car''s' using errcode = '22023';
  end if;
  insert into field_spends (staff_id, kind, spent_on, description, amount_cents, hst_cents, vehicle_id, booking_id, prep_task_id, paid_with, receipt_document_id)
  values (p_user, v_kind, v_on, left(btrim(p ->> 'description'), 300), v_amount, greatest(coalesce(nullif(p ->> 'hst_cents', '')::bigint, 0), 0), v_vehicle, v_booking,
          (select t.id from field_prep_tasks t where t.id = nullif(p ->> 'prep', '')::uuid and t.staff_id = p_user),
          case when p ->> 'paid_with' = 'company' then 'company' else 'own' end,
          app.fx_doc(p_user, p -> 'receipt', 'receipt', v_vehicle, v_booking, 'Receipt: ' || left(btrim(p ->> 'description'), 150)))
  returning id into v_id;
  perform app.fx_spend_after(v_id);
  return jsonb_build_object('id', v_id, 'receipt', (select receipt_document_id is not null from field_spends where id = v_id));
end $$;

create function app.fx_spend_receipt(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare x field_spends;
begin
  select * into x from field_spends where id = nullif(p ->> 'id', '')::uuid and staff_id = p_user;
  if x.id is null then raise exception 'That is not your spending' using errcode = '42501'; end if;
  if coalesce(p -> 'receipt' ->> 'storage_path', '') = '' then raise exception 'Take a photo of the receipt' using errcode = '22023'; end if;
  update field_spends set receipt_document_id = app.fx_doc(p_user, p -> 'receipt', 'receipt', x.vehicle_id, x.booking_id, 'Receipt: ' || left(x.description, 150)) where id = x.id;
  update tasks set status = 'done', completed_at = now(), completed_by = p_user, completion_note = 'Receipt added'
   where dedupe_key = 'field_receipt_missing:' || x.id and status in ('open', 'in_progress', 'waiting');
  return jsonb_build_object('id', x.id);
end $$;

-- the service's bill is made at once for field staff (the limit of an assistant does not apply: Finance checks the spending)
-- and a field service record may name no tracked item ("Repair or other work": the notes say what)
select pg_temp.patch_fn('app.maint_record(uuid, jsonb, text, uuid)'::regprocedure,
  $o$if p_source = 'manual' and jsonb_array_length(coalesce(p -> 'items', '[]'::jsonb)) = 0 then$o$,
  $n$if p_source = 'manual' and jsonb_array_length(coalesce(p -> 'items', '[]'::jsonb)) = 0 and coalesce(current_setting('app.fx_field_bill', true), '') <> 'on' then$n$);
select pg_temp.patch_fn('app.maint_bill_record(uuid, uuid)'::regprocedure,
  $o$if not app.user_is_admin(p_by) then$o$,
  $n$if not app.user_is_admin(p_by) and coalesce(current_setting('app.fx_field_bill', true), '') <> 'on' then$n$);

-- p: vehicle, done_on, items [codes], what, shop, odometer_km, cost_cents, hst_cents, paid_with, invoice {..}, prep, booking
create function app.fx_service_add(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid;
  v_cost bigint := coalesce(nullif(p ->> 'cost_cents', '')::bigint, 0);
  v_hst bigint := coalesce(nullif(p ->> 'hst_cents', '')::bigint, 0);
  v_items jsonb := coalesce(case when jsonb_typeof(p -> 'items') = 'array' then p -> 'items' end, '[]'::jsonb);
  v_what text := nullif(btrim(coalesce(p ->> 'what', '')), '');
  v_doc uuid;
  r jsonb;
  rec vehicle_service_records;
  v_spend uuid;
  v_name text;
begin
  if v_vehicle is null or not app.fx_may_car(p_user, v_vehicle) then raise exception 'This car is not on your list' using errcode = '42501'; end if;
  if v_what is null then raise exception 'Say what was done' using errcode = '22023'; end if;
  if nullif(btrim(coalesce(p ->> 'shop', '')), '') is null then raise exception 'Say where it was done' using errcode = '22023'; end if;
  if nullif(p ->> 'odometer_km', '') is null then raise exception 'Enter the odometer (km)' using errcode = '22023'; end if;
  if v_cost < 0 or v_cost > 2000000 then raise exception 'Check the cost' using errcode = '22023'; end if;
  if exists (select 1 from jsonb_array_elements_text(v_items) c where c not in (select code from service_items)) then raise exception 'Unknown service item' using errcode = '22023'; end if;
  v_doc := app.fx_doc(p_user, p -> 'invoice', 'repair_invoice', v_vehicle, null, 'Service invoice: ' || left(v_what, 150));
  perform set_config('app.fx_field_bill', 'on', true);
  r := app.maint_record(p_user, jsonb_build_object('vehicle_id', v_vehicle, 'done_on', coalesce(nullif(p ->> 'done_on', ''), app.today()::text),
         'odometer_km', p ->> 'odometer_km', 'shop', p ->> 'shop', 'notes', v_what, 'cost_cents', v_cost, 'hst_cents', v_hst,
         'items', coalesce((select jsonb_agg(jsonb_build_object('code', c)) from jsonb_array_elements_text(v_items) c), '[]'::jsonb),
         'receipt_document_id', v_doc, 'billed', true), 'manual');
  perform set_config('app.fx_field_bill', '', true);
  select * into rec from vehicle_service_records where id = (r ->> 'id')::uuid;
  if v_cost + v_hst > 0 then
    insert into field_spends (staff_id, kind, spent_on, description, amount_cents, hst_cents, vehicle_id, booking_id, prep_task_id, paid_with, receipt_document_id,
                              service_record_id, company_expense_id)
    values (p_user, 'service', rec.done_on, left('Service: ' || v_what || ' at ' || btrim(p ->> 'shop'), 300), greatest(v_cost, 1), v_hst, v_vehicle,
            nullif(p ->> 'booking', '')::uuid, (select t.id from field_prep_tasks t where t.id = nullif(p ->> 'prep', '')::uuid and t.staff_id = p_user),
            case when p ->> 'paid_with' = 'own' then 'own' else 'company' end, v_doc, rec.id, rec.company_expense_id)
    returning id into v_spend;
    perform app.fx_spend_after(v_spend);
  end if;
  select full_name into v_name from users where id = p_user;
  perform app.raise_task(p_type => 'field_service_fleet', p_title => format('Service recorded on %s by %s: %s', app.vehicle_name(v_vehicle), coalesce(v_name, 'field staff'), left(v_what, 120)),
    p_detail => format('At %s, %s km, %s. The timers were reset; check the car''s Maintenance tab.', btrim(p ->> 'shop'), p ->> 'odometer_km', app.fmt_money(v_cost + v_hst)),
    p_vehicle => v_vehicle, p_related_table => 'vehicle_service_records', p_related_id => rec.id, p_queue => 'fleet', p_dedupe => 'field_service_fleet:' || rec.id, p_created_by => p_user);
  perform app.staff_alert('field_service', 'vehicle_service_record', rec.id, 'new', format('Service on %s: %s', app.vehicle_name(v_vehicle), left(v_what, 80)),
    format('%s at %s, %s', coalesce(v_name, 'Field staff'), btrim(p ->> 'shop'), app.fmt_money(v_cost + v_hst)),
    jsonb_build_object('path_admin', '/admin/vehicles/' || v_vehicle, 'path_staff', '/staff/vehicles/' || v_vehicle));
  return jsonb_build_object('id', rec.id, 'billing_status', rec.billing_status, 'company_expense_id', rec.company_expense_id, 'spend_id', v_spend);
end $$;

-- Add > Photos: photos of a car with a note (on the car's documents)
create function app.fx_car_photo(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid;
  v_id uuid;
begin
  if v_vehicle is null or not app.fx_may_car(p_user, v_vehicle) then raise exception 'This car is not on your list today' using errcode = '42501'; end if;
  if coalesce(p -> 'photo' ->> 'storage_path', '') = '' then raise exception 'Take the photo' using errcode = '22023'; end if;
  v_id := app.fx_doc(p_user, p -> 'photo', 'other', v_vehicle, nullif(p ->> 'booking', '')::uuid, left('Field photo: ' || coalesce(nullif(btrim(p ->> 'note'), ''), 'no note'), 200));
  return jsonb_build_object('id', v_id);
end $$;

-- spare time: a listing photo shoot of a car, given to themselves (the photo shoot job of procedure 17 opens)
create function app.fx_photo_start(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid;
  v_id uuid;
begin
  if v_vehicle is null or not app.fx_may_car(p_user, v_vehicle) then raise exception 'This car is not on your list today' using errcode = '42501'; end if;
  select j.id into v_id from field_jobs j where j.vehicle_id = v_vehicle and j.kind = 'photo_shoot' and j.assigned_to = p_user and j.status not in ('done', 'cancelled') limit 1;
  if v_id is null then
    insert into field_jobs (kind, vehicle_id, assigned_to, scheduled_at, instructions, status, acknowledged_at, created_by)
    values ('photo_shoot', v_vehicle, p_user, now(), 'Listing photos in spare time: the angles the listing is missing.', 'acknowledged', now(), p_user)
    returning id into v_id;
  end if;
  return jsonb_build_object('job', v_id);
end $$;

-- ================================================================ 5. onboarding prep
-- p: vehicle, staff, day, items [codes], note
create function app.fx_prep_assign(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid;
  v_staff uuid := nullif(p ->> 'staff', '')::uuid;
  v_day date := nullif(p ->> 'day', '')::date;
  v_items text[] := array(select distinct x from jsonb_array_elements_text(coalesce(case when jsonb_typeof(p -> 'items') = 'array' then p -> 'items' end, '[]'::jsonb)) x);
  v_id uuid;
begin
  if not app.user_runs_fleet(p_by) then raise exception 'Only Fleet or an Admin gives onboarding prep' using errcode = '42501'; end if;
  if not exists (select 1 from vehicle_onboardings ob where ob.vehicle_id = v_vehicle and ob.status not in ('declined', 'withdrawn')) then
    raise exception 'This car is not being onboarded' using errcode = '23514';
  end if;
  if v_staff is null or not (app.is_field_person(v_staff) or app.user_is_admin(v_staff)) then raise exception 'Choose a field person' using errcode = '22023'; end if;
  if app.academy_locked(v_staff) then
    raise exception '% has not passed the academy yet', coalesce((select u.full_name from users u where u.id = v_staff), 'This person') using errcode = '23514';
  end if;
  if v_day is null or v_day < app.today() then raise exception 'Choose the day (today or later)' using errcode = '22023'; end if;
  if not app.user_is_admin(v_staff) and not exists (select 1 from field_shift_plans s where s.staff_id = v_staff and s.cancelled_at is null and app.local_date(s.starts_at) = v_day) then
    raise exception '% has no shift on %: choose a day they work', coalesce((select u.full_name from users u where u.id = v_staff), 'This person'), to_char(v_day, 'Mon DD') using errcode = '23514';
  end if;
  if cardinality(v_items) = 0 then raise exception 'Tick what to do' using errcode = '22023'; end if;
  insert into field_prep_tasks (vehicle_id, staff_id, work_day, items, note, created_by)
  values (v_vehicle, v_staff, v_day, v_items, nullif(btrim(coalesce(p ->> 'note', '')), ''), p_by) returning id into v_id;
  perform app.staff_alert('field_prep', 'field_prep_task', v_id, 'new', format('Onboarding prep on %s: %s', to_char(v_day, 'Mon DD'), app.vehicle_name(v_vehicle)),
    array_to_string(array(select app.fx_prep_label(c) from unnest(v_items) c), ', '), jsonb_build_object('assigned_to', v_staff, 'path_staff', '/staff/field'));
  return jsonb_build_object('id', v_id);
end $$;

create function app.fx_prep_cancel(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if not app.user_runs_fleet(p_by) then raise exception 'Only Fleet or an Admin takes onboarding prep off' using errcode = '42501'; end if;
  update field_prep_tasks set status = 'cancelled', cancelled_at = now(), cancelled_by = p_by where id = nullif(p ->> 'id', '')::uuid and status = 'planned';
  if not found then raise exception 'That prep is not open' using errcode = 'P0002'; end if;
  return jsonb_build_object('id', p ->> 'id');
end $$;

-- the onboarding checklist item a prep item completes
create function app.fx_prep_checklist_code(p_code text) returns text
language sql immutable as $$
  select case p_code when 'plates_permit' then 'registry_visit' when 'tracker' then 'tracker_install' when 'listing_photos' then 'photos' end
$$;

-- p: id, code, done (default true), note, document {..}, expires_on (the safety certificate)
create function app.fx_prep_item(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  t field_prep_tasks;
  v_code text := nullif(p ->> 'code', '');
  v_doc uuid;
  v_ck text;
  v_name text;
begin
  select * into t from field_prep_tasks where id = nullif(p ->> 'id', '')::uuid for update;
  if t.id is null or (t.staff_id <> p_user and not app.user_runs_fleet(p_user)) then raise exception 'That prep is not yours' using errcode = '42501'; end if;
  if t.status <> 'planned' then raise exception 'That prep is %', t.status using errcode = '23514'; end if;
  if v_code is null or not v_code = any (t.items) then raise exception 'That item is not on this prep' using errcode = '22023'; end if;
  if not coalesce((p ->> 'done')::boolean, true) then
    update field_prep_tasks set done = done - v_code where id = t.id;
    return jsonb_build_object('id', t.id, 'code', v_code, 'done', false);
  end if;
  if v_code = 'safety_certificate' and coalesce(p -> 'document' ->> 'storage_path', '') = '' then
    raise exception 'Upload the safety certificate (PDF or photo)' using errcode = '22023';
  end if;
  v_doc := app.fx_doc(p_user, p -> 'document', case v_code when 'safety_certificate' then 'safety_certificate' when 'plates_permit' then 'ownership_permit' else 'other' end,
                      t.vehicle_id, null, app.fx_prep_label(v_code));
  if v_code = 'safety_certificate' and nullif(p ->> 'expires_on', '') is not null then
    perform app.maint_record(p_user, jsonb_build_object('vehicle_id', t.vehicle_id, 'items', jsonb_build_array(jsonb_build_object('code', 'safety_certificate', 'expires_on', p ->> 'expires_on')),
      'payer', 'none', 'billed', false, 'notes', 'Safety certificate from onboarding prep', 'receipt_document_id', v_doc), 'manual');
  end if;
  update field_prep_tasks set done = done || jsonb_build_object(v_code, jsonb_build_object('at', now(), 'by', p_user, 'note', nullif(btrim(coalesce(p ->> 'note', '')), ''),
           'documents', case when v_doc is not null then jsonb_build_array(v_doc) else '[]'::jsonb end)) where id = t.id;
  -- the owner onboarding checklist
  v_ck := app.fx_prep_checklist_code(v_code);
  if v_ck is not null then
    update vehicle_onboardings set checklist_marks = checklist_marks || jsonb_build_object(v_ck, jsonb_build_object('status', 'done', 'by', p_user, 'at', now(), 'note', 'Done in onboarding prep'))
     where vehicle_id = t.vehicle_id;
    if v_ck = 'tracker_install' then update vehicle_onboardings set tracker_installed_at = coalesce(tracker_installed_at, now()) where vehicle_id = t.vehicle_id; end if;
  end if;
  if v_code = 'cleaning' then
    insert into vehicle_clean_checks (vehicle_id, moment, clean, note, photo_document_id, checked_by) values (t.vehicle_id, 'routine', true, 'Onboarding prep', v_doc, p_user);
  end if;
  select * into t from field_prep_tasks where id = t.id;
  if not exists (select 1 from unnest(t.items) c where not t.done ? c) then
    update field_prep_tasks set status = 'done', completed_at = now() where id = t.id;
    select full_name into v_name from users where id = t.staff_id;
    perform app.raise_task(p_type => 'field_prep_done', p_title => format('Onboarding prep done on %s by %s', app.vehicle_name(t.vehicle_id), coalesce(v_name, 'field staff')),
      p_detail => 'Check the uploads and the onboarding checklist.', p_vehicle => t.vehicle_id, p_related_table => 'field_prep_tasks', p_related_id => t.id,
      p_queue => 'fleet', p_dedupe => 'field_prep_done:' || t.id, p_created_by => p_user);
  end if;
  return jsonb_build_object('id', t.id, 'code', v_code, 'done', true, 'status', (select status from field_prep_tasks where id = t.id));
end $$;

-- the prep of a car (Fleet and Admin, the onboarding page; the field board)
create function app.fx_prep_list(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.user_runs_fleet(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return jsonb_build_object(
    'tasks', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'vehicle_id', t.vehicle_id, 'vehicle_name', app.vehicle_name(t.vehicle_id), 'staff_id', t.staff_id,
                 'staff_name', (select u.full_name from users u where u.id = t.staff_id), 'day', t.work_day, 'status', t.status, 'note', t.note,
                 'items', (select jsonb_agg(jsonb_build_object('code', c, 'label', app.fx_prep_label(c), 'done', t.done ? c)) from unnest(t.items) c),
                 'done_count', (select count(*) from unnest(t.items) c where t.done ? c), 'total', cardinality(t.items),
                 'spent_cents', (select coalesce(sum(s.amount_cents + s.hst_cents), 0) from field_spends s where s.prep_task_id = t.id and s.status <> 'refused'))
                 order by t.work_day desc, t.created_at desc)
               from field_prep_tasks t where t.status <> 'cancelled' and (nullif(p ->> 'vehicle', '') is null or t.vehicle_id = (p ->> 'vehicle')::uuid)
                 and (nullif(p ->> 'vehicle', '') is not null or t.status = 'planned' or t.completed_at > now() - interval '14 days')), '[]'::jsonb),
    'cars', case when nullif(p ->> 'vehicle', '') is null then coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id)) order by v.created_at)
               from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id
              where ob.status not in ('declined', 'withdrawn', 'enrolled') and v.status not in ('declined', 'exited', 'total_loss')), '[]'::jsonb) end,
    'people', coalesce((select jsonb_agg(s) from jsonb_array_elements(app.field_staff_board()) s where (s ->> 'eligible')::boolean), '[]'::jsonb),
    'tracker', coalesce((app.settings()).trackers_available, false));
end $$;

-- ================================================================ 6. Fleet: each person's list and completion
create function app.fx_work_lists(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare d date := coalesce(nullif(p ->> 'day', '')::date, app.today());
begin
  if not app.user_runs_fleet(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return jsonb_build_object('day', d, 'people', coalesce((select jsonb_agg(x.o order by x.name) from (
    select u.full_name as name, jsonb_build_object('id', u.id, 'name', u.full_name,
             'shift', (select jsonb_build_object('starts_at', s.starts_at, 'ends_at', s.ends_at) from field_shift_plans s where s.staff_id = u.id and s.cancelled_at is null and app.local_date(s.starts_at) = d order by s.starts_at limit 1),
             'clocked_in', exists (select 1 from field_shifts f where f.staff_id = u.id and f.ended_at is null and f.voided_at is null),
             'must', (t -> 'counts' ->> 'must')::int, 'done', (t -> 'counts' ->> 'done')::int,
             'cards', (select coalesce(jsonb_agg(jsonb_build_object('key', c ->> 'key', 'type', c ->> 'type', 'leg', c ->> 'leg', 'at', c ->> 'at', 'vehicle', c #>> '{vehicle,name}',
                         'booking', c #>> '{booking,number}', 'done', (c ->> 'done')::boolean)), '[]'::jsonb) from jsonb_array_elements(t -> 'cards') c where (c ->> 'must')::boolean),
             'left_open', coalesce((select jsonb_agg(jsonb_build_object('label', i.label, 'reason', i.reason, 'at', i.created_at)) from field_clock_open_items i
                                     where i.staff_id = u.id and app.local_date(i.created_at) = d), '[]'::jsonb)) as o
      from users u cross join lateral (select app.fx_today(u.id, d) as t) z(t)
     where (app.is_field_person(u.id) or app.admin_field_jobs(u.id))
       and (exists (select 1 from field_shift_plans s where s.staff_id = u.id and s.cancelled_at is null and app.local_date(s.starts_at) = d)
            or (t -> 'counts' ->> 'must')::int > 0)) x), '[]'::jsonb));
end $$;

-- ================================================================ 7. clock out: the must-dos still open need a reason
alter function app.field_clock_out(uuid, jsonb) rename to field_clock_out_pre0930;
create function app.field_clock_out(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_open jsonb := app.fx_open_musts(p_by, app.today());
  v_reasons jsonb := coalesce(case when jsonb_typeof(p -> 'open_reasons') = 'object' then p -> 'open_reasons' end, '{}'::jsonb);
  v_shift uuid;
  v_missing text;
  x jsonb;
  v_out jsonb;
  v_name text;
begin
  select string_agg(o ->> 'label', '; ') into v_missing from jsonb_array_elements(v_open) o
   where length(btrim(coalesce(v_reasons ->> (o ->> 'key'), ''))) < 3;
  if v_missing is not null then
    raise exception 'Still open: %. Give a reason for each before you clock out', v_missing using errcode = '23514';
  end if;
  select id into v_shift from field_shifts where staff_id = p_by and ended_at is null and voided_at is null;
  v_out := app.field_clock_out_pre0930(p_by, p);
  if jsonb_array_length(v_open) > 0 then
    for x in select * from jsonb_array_elements(v_open) loop
      insert into field_clock_open_items (shift_id, staff_id, item_key, label, reason)
      values (v_shift, p_by, left(x ->> 'key', 120), left(x ->> 'label', 300), left(btrim(v_reasons ->> (x ->> 'key')), 300));
    end loop;
    select full_name into v_name from users where id = p_by;
    perform app.raise_task(p_type => 'field_clock_open', p_title => format('%s clocked out with %s must-do(s) open', coalesce(v_name, 'A field person'), jsonb_array_length(v_open)),
      p_detail => left((select string_agg((o ->> 'label') || ': ' || btrim(v_reasons ->> (o ->> 'key')), E'\n') from jsonb_array_elements(v_open) o), 2000),
      p_related_table => 'field_shifts', p_related_id => v_shift, p_queue => 'fleet', p_dedupe => 'field_clock_open:' || coalesce(v_shift::text, p_by::text || app.today()::text), p_created_by => p_by);
    perform app.staff_alert('field_clock_open', 'field_shift', v_shift, 'open', format('%s clocked out with work open', coalesce(v_name, 'A field person')),
      left((select string_agg(o ->> 'label', '; ') from jsonb_array_elements(v_open) o), 240), jsonb_build_object('path_admin', '/admin/field-jobs', 'path_staff', '/staff/fleet'));
  end if;
  return v_out;
end $$;
select pg_temp.copy_grants('app.field_clock_out(uuid, jsonb)'::regprocedure, 'app.field_clock_out_pre0930(uuid, jsonb)'::regprocedure);

-- ================================================================ 8. the add-ons stop the pickup until ticked (or an Admin overrides)
create or replace function app.fx_addons_blocking(p_booking uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.fx_addons_open(p_booking) > 0
     and exists (select 1 from field_jobs j where j.booking_id = p_booking and j.kind in ('handover', 'delivery') and j.status not in ('done', 'cancelled'))
$$;

alter function app.handover_blockers(uuid, uuid, text, jsonb) rename to handover_blockers_pre0930;
create function app.handover_blockers(p_by uuid, p_booking uuid, p_kind text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v jsonb := app.handover_blockers_pre0930(p_by, p_booking, p_kind, p);
begin
  if p_kind in ('pickup', 'past_trip') and app.fx_addons_blocking(p_booking) then
    v := v || jsonb_build_array(jsonb_build_object('code', 'addons', 'label', app.override_label('addons')));
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.handover_blockers(uuid, uuid, text, jsonb)'::regprocedure, 'app.handover_blockers_pre0930(uuid, uuid, text, jsonb)'::regprocedure);

alter function app.override_label(text) rename to override_label_pre0930;
create function app.override_label(p_code text) returns text
language sql immutable as $$
  select case p_code when 'addons' then 'The add-ons are not ticked as in the car' else app.override_label_pre0930(p_code) end
$$;
select pg_temp.copy_grants('app.override_label(text)'::regprocedure, 'app.override_label_pre0930(text)'::regprocedure);

-- ================================================================ 8b. Finance: the spending list, approve or refuse, paid back
create function app.fx_spends_list(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.user_runs_finance(p_by) then raise exception 'Only Finance or an Admin handles field spending' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'staff', (select u.full_name from users u where u.id = s.staff_id), 'kind', s.kind, 'spent_on', s.spent_on,
           'description', s.description, 'amount_cents', s.amount_cents, 'hst_cents', s.hst_cents, 'vehicle', app.vehicle_name(s.vehicle_id),
           'booking', (select b.booking_number from bookings b where b.id = s.booking_id), 'paid_with', s.paid_with, 'status', s.status, 'note', s.decision_note,
           'receipt_path', (select d.storage_path from documents d where d.id = s.receipt_document_id and d.purged_at is null),
           'service', s.service_record_id is not null, 'expense', s.company_expense_id is not null, 'created_at', s.created_at) order by s.created_at desc)
    from (select * from field_spends x
           where case coalesce(p ->> 'show', 'open') when 'all' then x.created_at > now() - interval '90 days'
                   else x.status = 'submitted' or (x.status = 'approved' and x.paid_with = 'own') end
           order by x.created_at desc limit 200) s), '[]'::jsonb);
end $$;

-- p: id, approve, note
create function app.fx_spend_decide(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x field_spends;
  v_ok boolean := coalesce((p ->> 'approve')::boolean, false);
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  v_exp uuid;
  v_on date;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Only Finance or an Admin approves field spending' using errcode = '42501'; end if;
  select * into x from field_spends where id = nullif(p ->> 'id', '')::uuid for update;
  if x.id is null then raise exception 'Not found' using errcode = 'P0002'; end if;
  if x.status <> 'submitted' then raise exception 'This was already %', x.status using errcode = '23514'; end if;
  if not v_ok and length(coalesce(v_note, '')) < 3 then raise exception 'Say why it is refused' using errcode = '22023'; end if;
  if v_ok then
    v_exp := x.company_expense_id;
    if v_exp is null and x.service_record_id is null then
      v_on := case when exists (select 1 from company_statements cs where cs.statement_month = app.month_start(x.spent_on) and cs.status = 'final') then app.today() else x.spent_on end;
      insert into company_expenses (expense_on, category, description, amount_cents, hst_cents, vehicle_id, owner_id, staff_user_id, document_id, created_by)
      values (v_on, app.fx_spend_category(x.kind), left('Field staff: ' || x.description, 500), x.amount_cents, x.hst_cents, x.vehicle_id,
              (select v.owner_id from vehicles v where v.id = x.vehicle_id), x.staff_id, x.receipt_document_id, p_by)
      returning id into v_exp;
    end if;
    update field_spends set status = 'approved', company_expense_id = v_exp, decided_by = p_by, decided_at = now(), decision_note = v_note where id = x.id;
  else
    if x.company_expense_id is not null then
      update company_expenses set voided_at = now(), void_reason = left('Refused by Finance: ' || v_note, 300) where id = x.company_expense_id and voided_at is null;
    end if;
    update field_spends set status = 'refused', decided_by = p_by, decided_at = now(), decision_note = v_note where id = x.id;
    update tasks set status = 'cancelled', completed_at = now(), completed_by = p_by where dedupe_key = 'field_receipt_missing:' || x.id and status in ('open', 'in_progress', 'waiting');
  end if;
  update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = case when v_ok then 'Approved' else 'Refused' end
   where dedupe_key = 'field_spend_review:' || x.id and status in ('open', 'in_progress', 'waiting');
  return jsonb_build_object('id', x.id, 'status', (select status from field_spends where id = x.id), 'company_expense_id', v_exp);
end $$;

create function app.fx_spend_paid_back(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare x field_spends;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Only Finance or an Admin pays back field spending' using errcode = '42501'; end if;
  select * into x from field_spends where id = nullif(p ->> 'id', '')::uuid for update;
  if x.id is null or x.status <> 'approved' or x.paid_with <> 'own' then raise exception 'Only approved spending paid with their own money is paid back' using errcode = '23514'; end if;
  update field_spends set status = 'reimbursed', reimbursed_by = p_by, reimbursed_at = now(), decision_note = coalesce(nullif(btrim(coalesce(p ->> 'note', '')), ''), decision_note) where id = x.id;
  return jsonb_build_object('id', x.id, 'status', 'reimbursed');
end $$;

-- ================================================================ 9. renter help: find a booking
create function app.fx_help_find(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  q text := btrim(coalesce(p ->> 'q', ''));
  v_digits text := regexp_replace(q, '[^0-9]', '', 'g');
  v jsonb;
begin
  if length(q) < 3 then raise exception 'Type at least 3 letters or digits' using errcode = '22023'; end if;
  select coalesce(jsonb_agg(x.o order by x.at), '[]'::jsonb) into v from (
    select jsonb_build_object('id', b.id, 'number', b.booking_number, 'status', b.status, 'pickup_at', b.pickup_at, 'return_at', b.return_at,
             'renter', r.legal_name, 'vehicle', app.vehicle_name(b.vehicle_id), 'mine', exists (select 1 from field_jobs j where j.booking_id = b.id and j.assigned_to = p_user and j.status <> 'cancelled')) as o,
           b.pickup_at as at
      from bookings b left join renters r on r.id = b.renter_id
     where b.status in ('pending_payment', 'confirmed', 'on_rent') and not coalesce(b.is_placeholder, false)
       and b.pickup_at < now() + interval '14 days'
       and (b.booking_number = upper(q) or r.legal_name ilike '%' || q || '%'
            or (length(v_digits) >= 7 and regexp_replace(coalesce(r.mobile, ''), '[^0-9]', '', 'g') like '%' || right(v_digits, 10)))
     order by b.pickup_at limit 10) x;
  insert into data_access_log (user_id, action, query, results) values (p_user, 'search', 'field help: ' || left(q, 100), jsonb_array_length(v));
  return v;
end $$;

-- one booking for renter help: what is open (money, deposit, signature, licences) in plain facts
create function app.fx_help_booking(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_ready jsonb;
  v_job uuid;
begin
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  if b.id is null or b.status not in ('pending_payment', 'confirmed', 'on_rent') then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  select j.id into v_job from field_jobs j where j.booking_id = b.id and j.assigned_to = p_user and j.status not in ('cancelled') order by j.scheduled_at limit 1;
  if v_job is null then
    insert into data_access_log (user_id, action, query, results) values (p_user, 'open', 'field help: ' || b.booking_number, 1);
  end if;
  v_ready := app.booking_readiness(b.id);
  return jsonb_build_object('id', b.id, 'number', b.booking_number, 'status', b.status, 'pickup_at', b.pickup_at, 'return_at', b.return_at, 'job', v_job,
    'vehicle', app.vehicle_name(b.vehicle_id),
    'renter', (select jsonb_build_object('name', r.legal_name, 'mobile', r.mobile, 'email', coalesce(r.email, (select u.email from users u where u.id = r.user_id))) from renters r where r.id = b.renter_id),
    'open_cents', app.booking_part_open(b.id, 'rental') + app.booking_part_open(b.id, 'fees'),
    'deposit_cents', b.deposit_cents,
    'deposit', case when b.deposit_waived_at is not null then 'waived' when b.deposit_cents = 0 then 'none'
                    when exists (select 1 from deposits d where d.booking_id = b.id and d.status in ('held', 'captured')) then 'taken' else 'not_taken' end,
    'signed', b.booking_type = 'owner' or exists (select 1 from signature_requests s where s.id = b.signature_request_id and s.status = 'completed'),
    'identity', coalesce((v_ready ->> 'all_drivers_verified')::boolean, false),
    'drivers', coalesce((select jsonb_agg(jsonb_build_object('name', d.full_name, 'role', d.role, 'verified', d.identity_verified_on is not null) order by d.role desc, d.full_name)
                          from booking_drivers d where d.booking_id = b.id), '[]'::jsonb),
    'addons', app.fx_addons(b.id));
end $$;

-- ================================================================ 10. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0930;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if p_call = 'field_read' and p_name in ('today', 'help_find', 'help_booking', 'open_musts', 'my_spends', 'job_card') then
    perform app.door_begin(p_user, p_aal);
    if not app.user_is_field(p_user) then raise exception 'Only field staff may do this' using errcode = '42501'; end if;
    return case p_name
      when 'today' then app.fx_today(p_user, nullif(p_ ->> 'day', '')::date)
      when 'help_find' then app.fx_help_find(p_user, p_)
      when 'help_booking' then app.fx_help_booking(p_user, p_)
      when 'open_musts' then app.fx_open_musts(p_user, app.today())
      when 'job_card' then (select app.fx_job_card(p_user, j) from field_jobs j where j.id = nullif(p_ ->> 'id', '')::uuid and j.assigned_to = p_user and j.status <> 'cancelled')
      else coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'kind', s.kind, 'spent_on', s.spent_on, 'description', s.description, 'amount_cents', s.amount_cents + s.hst_cents,
                       'status', s.status, 'receipt', s.receipt_document_id is not null, 'vehicle', app.vehicle_name(s.vehicle_id), 'note', s.decision_note) order by s.spent_on desc, s.created_at desc)
                     from (select * from field_spends x where x.staff_id = p_user order by x.created_at desc limit 50) s), '[]'::jsonb) end;
  end if;
  if p_call = 'field_do' and p_name in ('addon_tick', 'clean_check', 'car_update', 'spend_add', 'spend_receipt', 'service_add', 'photo_start', 'prep_item', 'car_photo') then
    perform app.door_begin(p_user, p_aal);
    if not app.user_is_field(p_user) then raise exception 'Only field staff may do this' using errcode = '42501'; end if;
    return case p_name
      when 'addon_tick' then app.fx_addon_tick(p_user, p_)
      when 'clean_check' then app.fx_clean_check(p_user, p_)
      when 'car_update' then app.fx_car_update(p_user, p_)
      when 'spend_add' then app.fx_spend_add(p_user, p_)
      when 'spend_receipt' then app.fx_spend_receipt(p_user, p_)
      when 'service_add' then app.fx_service_add(p_user, p_)
      when 'photo_start' then app.fx_photo_start(p_user, p_)
      when 'car_photo' then app.fx_car_photo(p_user, p_)
      else app.fx_prep_item(p_user, p_) end;
  end if;
  -- the field handover: every add-on ticked as in the car first (an Admin's override records the pickup on the booking instead)
  if p_call = 'field_do' and p_name = 'complete_handover' then
    if exists (select 1 from field_jobs j where j.id = nullif(p_ ->> 'job', '')::uuid and j.booking_id is not null and app.fx_addons_open(j.booking_id) > 0) then
      raise exception 'Tick each add-on as in the car first: %. Or ask an Admin to override',
        (select string_agg(a ->> 'name', ', ') from field_jobs j cross join jsonb_array_elements(app.fx_addons(j.booking_id)) a
          where j.id = (p_ ->> 'job')::uuid and not (a ->> 'ticked')::boolean) using errcode = '23514';
    end if;
  end if;
  if (p_call = 'ops_read' and p_name in ('field_work_lists', 'field_prep', 'field_spends')) or (p_call = 'ops_do' and p_name in ('field_prep_assign', 'field_prep_cancel', 'field_spend_decide', 'field_spend_paid_back')) then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return case p_name
      when 'field_work_lists' then app.fx_work_lists(p_user, p_)
      when 'field_prep' then app.fx_prep_list(p_user, p_)
      when 'field_prep_assign' then app.fx_prep_assign(p_user, p_)
      when 'field_spends' then app.fx_spends_list(p_user, p_)
      when 'field_spend_decide' then app.fx_spend_decide(p_user, p_)
      when 'field_spend_paid_back' then app.fx_spend_paid_back(p_user, p_)
      else app.fx_prep_cancel(p_user, p_) end;
  end if;
  return app.door_pre0930(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0930(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and (p.proname like 'fx\_%' or p.proname in ('door_pre0930', 'field_clock_out_pre0930', 'handover_blockers_pre0930', 'override_label_pre0930'))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
