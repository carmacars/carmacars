-- 0263: the three handover essentials, a hard priority (the owner, Release 24b): the driver's licence approved, the
-- rental agreement signed (and countersigned), the check-out photos (and at return the check-in photos, km and fuel).
-- docs/changes/2026-11-04-handover-essentials.md.
--
-- What the database already refuses, unchanged: no car is released (on_rent) until every driver's identity is verified
-- (0011, 0016), the agreement is signed (0051, 0185), the deposit is held or waived by an Admin with a reason (0019), and
-- the pickup Condition Report has every photo, the km and the fuel (0020); a return is not checked in without its photos,
-- km and fuel (0020). This migration adds what reaches the people before the day:
-- 1. The renter is reminded before the pickup day of what is still missing (the licence to upload, the agreement to
--    sign): by text by default (program_settings.essentials_reminders: text, email or off), by email when there is no
--    mobile or the text cannot go. Once per booking and missing item, the day before pickup from 10:00 Toronto time (or at
--    once when the booking is made later than that).
-- 2. Staff get a task "Pickup tomorrow: missing ..." the evening before pickup (program_settings.essentials_task_hour, 18),
--    naming what is missing: the licence approval, the signature, the deposit (no saved card for the automatic hold and
--    no hold yet), the coverage.
-- 3. app.handover_essentials(booking): the list with what is done, for the booking page, the field job and the tests.
-- Both run from the Worker's five-minute tick (server_jobs_due), cheaply: a quarter-hour at most, bookings picked up
-- within two days only.
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

alter table program_settings add column if not exists essentials_reminders text not null default 'text' check (essentials_reminders in ('text', 'email', 'off'));
alter table program_settings add column if not exists essentials_task_hour integer not null default 18 check (essentials_task_hour between 12 and 23);
comment on column program_settings.essentials_reminders is 'Before the pickup day, remind the renter of the licence to upload and the agreement to sign (0263): text (the default, email when no mobile), email, or off.';
comment on column program_settings.essentials_task_hour is 'The hour (Toronto) the evening before pickup staff get a task for anything still missing for the handover (0263).';


insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description)
values ('handover_essentials', 'cs', 'Pickup tomorrow: something is missing', 'high', 'none', null, 3, null,
        'The evening before pickup: the licence approval, the signature, the deposit or the coverage is still missing')
on conflict (task_type) do nothing;

-- ================================================================ 3. the essentials of a booking
create or replace function app.handover_essentials(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  v_licence boolean;
  v_signed boolean;
  v_deposit boolean;
  v_out boolean;
  v_back boolean;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return null; end if;
  v_licence := exists (select 1 from booking_drivers d where d.booking_id = b.id and d.role = 'renter')
               and not exists (select 1 from booking_drivers d where d.booking_id = b.id and d.identity_verified_on is null);
  v_signed := b.agreement_on_paper or exists (select 1 from signature_requests s where s.id = b.signature_request_id and s.status = 'completed');
  v_deposit := b.booking_type = 'owner' or coalesce(b.deposit_cents, 0) = 0 or b.deposit_waived_at is not null
               or exists (select 1 from deposits d where d.booking_id = b.id and d.status in ('held', 'captured', 'settled'));
  v_out := exists (select 1 from condition_reports c where c.booking_id = b.id and c.kind = 'pickup' and c.completed_at is not null);
  v_back := exists (select 1 from condition_reports c where c.booking_id = b.id and c.kind = 'return' and c.completed_at is not null
                      and c.odometer_km is not null and c.fuel_pct is not null);
  return jsonb_build_object('licence', v_licence, 'agreement', v_signed, 'deposit', v_deposit, 'checkout_photos', v_out, 'checkin', v_back,
    'ready_for_handover', v_licence and v_signed and v_deposit);
end $$;

-- ================================================================ 1 and 2. the reminders and the evening task
create or replace function app.essentials_sweep(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  r bookings;
  e jsonb;
  v_local timestamp := p_now at time zone 'America/Toronto';
  v_today date := (p_now at time zone 'America/Toronto')::date;
  v_missing text[];
  v_renter text[];
  rn renters;
  o phone_outbox;
  v_url text;
  v_body text;
  v_texts integer := 0;
  v_emails integer := 0;
  v_tasks integer := 0;
  v_email text;
begin
  for r in select b.* from bookings b
            where b.status = 'confirmed' and b.booking_type <> 'owner'
              and b.pickup_at > p_now and b.pickup_at <= p_now + interval '48 hours'
              and (b.pickup_at at time zone 'America/Toronto')::date = v_today + 1 loop
    e := app.handover_essentials(r.id);
    -- 1. the renter: what they can do themselves, the day before, from 10:00
    v_renter := array_remove(array[case when not (e ->> 'licence')::boolean and not exists (
                     select 1 from booking_drivers d join drivers dr on dr.id = d.driver_id
                      where d.booking_id = r.id and d.role = 'renter' and dr.identity_status in ('pending', 'verified')) then 'upload your driver''s licence (a photo or a PDF scan)' end,
                   case when not (e ->> 'agreement')::boolean then 'sign the rental agreement' end], null);
    if s.essentials_reminders <> 'off' and cardinality(v_renter) > 0 and extract(hour from v_local) >= 10 and extract(hour from v_local) < 21
       and not exists (select 1 from booking_events x where x.booking_id = r.id and x.kind = 'adjusted' and x.details ->> 'essentials_reminder' = v_today::text) then
      select * into rn from renters where id = r.renter_id;
      v_url := rtrim(s.notify_base_url, '/') || '/account/bookings/' || r.booking_number;
      v_body := format('CarmaCars: booking %s, pickup tomorrow %s at %s. Before pickup, please %s: %s',
                       r.booking_number, app.fmt_date(r.pickup_at), app.fmt_time(r.pickup_at), array_to_string(v_renter, ' and '), v_url);
      o := null;
      if s.essentials_reminders = 'text' and app.phone_e164(rn.mobile) is not null then
        o := app.phone_outbox_put(rn.mobile, v_body, 'booking', r.id, rn.id, 'essentials', null, 'essentials:' || r.id || ':' || v_today, p_now);
      end if;
      if o.id is not null and o.status <> 'skipped' then
        v_texts := v_texts + 1;
      else
        v_email := coalesce(rn.email, (select u.email from users u where u.id = rn.user_id));
        if v_email is not null then
          perform app.staff_send_message(null, r.id, 'Before your pickup: booking ' || r.booking_number,
            format('Hi %s, your pickup is tomorrow, %s at %s. Before pickup, please %s here: %s. The car is released only once this is done.',
                   coalesce(nullif(split_part(btrim(rn.legal_name), ' ', 1), ''), 'there'), app.fmt_date(r.pickup_at), app.fmt_time(r.pickup_at), array_to_string(v_renter, ' and '), v_url));
          v_emails := v_emails + 1;
        end if;
      end if;
      perform app.log_booking_event(r.id, 'adjusted', r.status::text, r.status::text, null,
        'Reminder to the renter before pickup: ' || array_to_string(v_renter, ' and '), null, 'system', jsonb_build_object('essentials_reminder', v_today::text));
    end if;
    -- 2. staff: the evening before, anything missing
    if extract(hour from v_local) >= s.essentials_task_hour then
      v_missing := array_remove(array[
        case when not (e ->> 'licence')::boolean then 'the licence approved' end,
        case when not (e ->> 'agreement')::boolean then 'the agreement signed' end,
        case when not (e ->> 'deposit')::boolean and not app.deposit_auto_card_ok(r) and r.deposit_pay_method = 'card' then 'a card for the deposit hold' end,
        case when r.coverage_confirmed_at is null then 'the coverage confirmed' end], null);
      if cardinality(v_missing) > 0 then
        perform app.raise_task(p_type => 'handover_essentials', p_title => format('Pickup tomorrow: %s missing %s', r.booking_number, array_to_string(v_missing, ', ')),
          p_detail => format('Pickup %s at %s. No car is released without the licence approved, the agreement signed and the deposit taken (or waived by an Admin). Still missing: %s.',
                             app.fmt_date(r.pickup_at), app.fmt_time(r.pickup_at), array_to_string(v_missing, ', ')),
          p_booking => r.id, p_vehicle => r.vehicle_id, p_renter => r.renter_id, p_due_at => r.pickup_at - interval '2 hours', p_priority => 'high',
          p_dedupe => 'handover_essentials:' || r.id || ':' || v_today, p_queue => 'cs');
        v_tasks := v_tasks + 1;
      end if;
    end if;
  end loop;
  return jsonb_build_object('texts', v_texts, 'emails', v_emails, 'tasks', v_tasks);
end $$;

-- from the five-minute tick, a quarter-hour at most
alter function app.server_jobs_due() rename to server_jobs_due_pre0263;
create function app.server_jobs_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  j jsonb := app.server_jobs_due_pre0263();
begin
  -- the first tick of each quarter-hour (the tick runs every five minutes; a second run sends nothing twice)
  if extract(minute from now())::integer % 15 < 5 then
    begin
      perform app.essentials_sweep(now());
    exception when others then
      raise warning 'essentials sweep: %', sqlerrm;
    end;
  end if;
  return j;
end $$;
select pg_temp.copy_grants('app.server_jobs_due()'::regprocedure, 'app.server_jobs_due_pre0263()'::regprocedure);

-- the booking pages and the field job read the list
alter function app.field_read(uuid, text, jsonb) rename to field_read_pre0263;
create function app.field_read(p_user uuid, p_what text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x jsonb := app.field_read_pre0263(p_user, p_what, p);
begin
  if p_what = 'job' and x is not null and jsonb_typeof(x -> 'ready') = 'object' and (x #>> '{booking,id}') is not null then
    x := jsonb_set(x, '{ready,essentials}', coalesce(app.handover_essentials((x #>> '{booking,id}')::uuid), 'null'::jsonb));
  end if;
  return x;
end $$;
select pg_temp.copy_grants('app.field_read(uuid, text, jsonb)'::regprocedure, 'app.field_read_pre0263(uuid, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('handover_essentials', 'essentials_sweep', 'server_jobs_due_pre0263', 'field_read_pre0263') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
