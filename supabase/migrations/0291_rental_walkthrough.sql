-- 0291: the rental walkthrough (Release 25b, docs/changes/2026-11-05-rental-walkthrough.md). The renter is guided through
-- the whole rental, step by step, on one page of their booking (/account/bookings/<number>/walkthrough): before pickup
-- (the licence, the signature, the payment, the deposit hold on the day, what to bring), at pickup (where and when, the
-- walk-around of the car with our staff and the check-out photos, their own photos), on the road (fuel, kilometres,
-- tolls, smoking, what to do if something goes wrong) and at the return (how to bring it back, the check-in photos, the
-- deposit released). It fits the handover essentials (0263): the steps that are tasks are done when the database says
-- so (the licence approved, the agreement signed, paid, the deposit held, the check-out and check-in reports complete);
-- the steps the renter reads are done when they press "Got it". Field staff see on the job how much the renter has read.
--
-- 1. program_settings.field_renter_walkthrough (on by default): the walkthrough on the renter's booking.
-- 2. booking_walkthrough_steps: the steps a renter marked as read (booking, step, when, who).
-- 3. app.rental_walkthrough(booking): every step with its stage and whether it is done, the stage the trip is at.
--    public.server_my_walkthrough and server_my_walkthrough_ack: the renter of the booking only (service role).
-- 4. app.field_read('job') carries walkthrough: {read, of, done, total}.
-- No applied migration is edited.
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

alter table program_settings add column if not exists field_renter_walkthrough boolean not null default true;
comment on column program_settings.field_renter_walkthrough is 'The rental walkthrough on the renter''s booking (0291): before pickup, at pickup, on the road and at the return, step by step.';

create table if not exists booking_walkthrough_steps (
  booking_id uuid not null references bookings (id) on delete cascade,
  step       text not null check (step in ('bring', 'meet', 'own_photos', 'rules', 'help', 'return_prep')),
  seen_at    timestamptz not null default now(),
  user_id    uuid references users (id) on delete set null,
  primary key (booking_id, step)
);
comment on table booking_walkthrough_steps is 'The steps of the rental walkthrough a renter marked as read ("Got it", 0291).';
alter table booking_walkthrough_steps enable row level security;
revoke all on booking_walkthrough_steps from public, anon, authenticated;
grant select on booking_walkthrough_steps to authenticated;
grant select, insert, update, delete on booking_walkthrough_steps to service_role;
drop policy if exists admin_all on booking_walkthrough_steps;
create policy admin_all on booking_walkthrough_steps for select to authenticated using (app.is_admin());
create trigger audit_booking_walkthrough_steps after insert or update or delete on booking_walkthrough_steps for each row execute function app.audit_row();

-- ================================================================ 3. the steps of a booking
create or replace function app.rental_walkthrough(p_booking uuid, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  e jsonb;
  v_read jsonb;
  v_live boolean;
  v_paid boolean;
  v_stage text;
  v_steps jsonb;
  v_today date := app.local_date(p_now);
  v_held boolean;
  v_back boolean;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return null; end if;
  if not (app.settings()).field_renter_walkthrough or b.status in ('cancelled', 'expired', 'declined') or b.booking_type = 'owner' then
    return jsonb_build_object('enabled', false, 'booking_id', b.id);
  end if;
  e := app.handover_essentials(b.id);
  select coalesce(jsonb_object_agg(s.step, s.seen_at), '{}'::jsonb) into v_read from booking_walkthrough_steps s where s.booking_id = b.id;
  v_live := b.status in ('confirmed', 'on_rent', 'returned', 'closed');
  v_paid := v_live;
  v_held := exists (select 1 from deposits d where d.booking_id = b.id and d.status in ('pending', 'held', 'captured'));
  v_back := b.status = 'closed' or (b.checked_in_at is not null and not v_held);
  v_stage := case
    when b.status in ('returned', 'closed') or b.checked_in_at is not null then 'return'
    when b.status = 'on_rent' or b.handed_over_at is not null then case when b.return_at - p_now <= interval '24 hours' then 'return' else 'road' end
    when app.local_date(b.pickup_at) <= v_today then 'pickup'
    else 'before' end;
  v_steps := jsonb_build_array(
    jsonb_build_object('key', 'licence', 'stage', 'before', 'kind', 'task', 'done', coalesce((e ->> 'licence')::boolean, false) or b.handed_over_at is not null),
    jsonb_build_object('key', 'sign', 'stage', 'before', 'kind', 'task', 'done', coalesce((e ->> 'agreement')::boolean, false) or b.handed_over_at is not null),
    jsonb_build_object('key', 'pay', 'stage', 'before', 'kind', 'task', 'done', v_paid),
    jsonb_build_object('key', 'deposit', 'stage', 'before', 'kind', 'task', 'done', coalesce((e ->> 'deposit')::boolean, false) or b.handed_over_at is not null,
                       'needed', coalesce(b.deposit_cents, 0) > 0 and b.deposit_waived_at is null),
    jsonb_build_object('key', 'bring', 'stage', 'before', 'kind', 'read', 'done', v_read ? 'bring', 'at', v_read -> 'bring'),
    jsonb_build_object('key', 'meet', 'stage', 'pickup', 'kind', 'read', 'done', v_read ? 'meet' or b.handed_over_at is not null, 'at', v_read -> 'meet'),
    jsonb_build_object('key', 'inspect', 'stage', 'pickup', 'kind', 'task', 'done', coalesce((e ->> 'checkout_photos')::boolean, false) or b.handed_over_at is not null),
    jsonb_build_object('key', 'own_photos', 'stage', 'pickup', 'kind', 'read', 'done', v_read ? 'own_photos', 'at', v_read -> 'own_photos'),
    jsonb_build_object('key', 'rules', 'stage', 'road', 'kind', 'read', 'done', v_read ? 'rules', 'at', v_read -> 'rules'),
    jsonb_build_object('key', 'help', 'stage', 'road', 'kind', 'read', 'done', v_read ? 'help', 'at', v_read -> 'help'),
    jsonb_build_object('key', 'return_prep', 'stage', 'return', 'kind', 'read', 'done', v_read ? 'return_prep' or b.checked_in_at is not null, 'at', v_read -> 'return_prep'),
    jsonb_build_object('key', 'checkin', 'stage', 'return', 'kind', 'task', 'done', coalesce((e ->> 'checkin')::boolean, false) or b.status in ('returned', 'closed')),
    jsonb_build_object('key', 'deposit_back', 'stage', 'return', 'kind', 'task', 'done', v_back));
  return jsonb_build_object('enabled', true, 'booking_id', b.id, 'stage', v_stage, 'status', b.status, 'steps', v_steps,
    'done', (select count(*) from jsonb_array_elements(v_steps) x where (x ->> 'done')::boolean),
    'total', jsonb_array_length(v_steps),
    'read', (select count(*) from jsonb_array_elements(v_steps) x where x ->> 'kind' = 'read' and (x ->> 'done')::boolean),
    'of', (select count(*) from jsonb_array_elements(v_steps) x where x ->> 'kind' = 'read'));
end $$;
comment on function app.rental_walkthrough(uuid, timestamptz) is 'The rental walkthrough of a booking (0291): each step, its stage (before, pickup, road, return), done or not, and the stage the trip is at.';

create or replace function app.rental_walkthrough_ack(p_booking uuid, p_by uuid, p_step text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
begin
  perform app.assert_booking_renter(p_booking, p_by);
  select * into b from bookings where id = p_booking;
  if b.status in ('cancelled', 'expired', 'declined') then raise exception 'This booking is not going ahead' using errcode = '22023'; end if;
  if p_step is null or p_step not in ('bring', 'meet', 'own_photos', 'rules', 'help', 'return_prep') then
    raise exception 'Unknown step' using errcode = '22023';
  end if;
  insert into booking_walkthrough_steps (booking_id, step, user_id) values (p_booking, p_step, p_by)
  on conflict (booking_id, step) do nothing;
  return app.rental_walkthrough(p_booking);
end $$;

create or replace function public.server_my_walkthrough(p_booking uuid, p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_booking_renter(p_booking, p_by);
  return app.rental_walkthrough(p_booking);
end $$;
create or replace function public.server_my_walkthrough_ack(p_booking uuid, p_by uuid, p_step text) returns jsonb
language sql security definer set search_path = public, app as $$ select app.rental_walkthrough_ack(p_booking, p_by, p_step) $$;

-- ================================================================ 4. the field job shows how much the renter read
alter function app.field_read(uuid, text, jsonb) rename to field_read_pre0291;
create function app.field_read(p_user uuid, p_what text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x jsonb := app.field_read_pre0291(p_user, p_what, p);
  w jsonb;
begin
  if p_what = 'job' and x is not null and (x #>> '{booking,id}') is not null then
    w := app.rental_walkthrough((x #>> '{booking,id}')::uuid);
    if coalesce((w ->> 'enabled')::boolean, false) then
      x := x || jsonb_build_object('walkthrough', jsonb_build_object('read', w -> 'read', 'of', w -> 'of', 'done', w -> 'done', 'total', w -> 'total', 'stage', w -> 'stage'));
    end if;
  end if;
  return x;
end $$;
select pg_temp.copy_grants('app.field_read(uuid, text, jsonb)'::regprocedure, 'app.field_read_pre0291(uuid, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname in ('rental_walkthrough', 'rental_walkthrough_ack', 'field_read_pre0291'))
               or (n.nspname = 'public' and p.proname in ('server_my_walkthrough', 'server_my_walkthrough_ack')) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
