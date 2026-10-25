-- 0145: long rentals, second part (docs/changes/2026-10-25-long-rentals-2.md)
--
-- 1. Drafts. The owner: "Need a way to partially input a rental and finish it later because my staff is standing in the
--    cold and trying to fill all the fields." Add a rental and Send an offer save as they are typed (rental_drafts, one
--    per form and staff member, nothing required), resume on any device, and list as Unfinished rentals. A draft holds
--    the car only when Hold the car is ticked (a calendar block of two hours, renewed while the draft is saved).
--    Quick start at pickup: the renter's name and phone, the car, the kilometres and the fuel, the pickup now; the car is
--    held and the staff member gets a task to finish it; the readings go on the rental when it is added.

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0145: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. drafts
create table if not exists rental_drafts (
  id           uuid primary key default gen_random_uuid(),
  kind         text not null check (kind in ('rental', 'offer')),
  created_by   uuid not null references users (id),
  updated_by   uuid references users (id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  status       text not null default 'open' check (status in ('open', 'done', 'discarded')),
  quick        boolean not null default false,
  data         jsonb not null default '{}'::jsonb,
  title        text,
  vehicle_id   uuid references vehicles (id),
  hold_block_id uuid references vehicle_calendar_blocks (id),
  booking_id   uuid references bookings (id),
  finished_at  timestamptz
);
comment on table rental_drafts is 'A rental or an offer being entered, saved as it is typed (0145): its form fields (data), who started it, the car held for it while Hold the car is ticked, and the booking it became.';
create index if not exists rental_drafts_open on rental_drafts (status, updated_at desc) where status = 'open';
create trigger rental_drafts_updated before update on rental_drafts for each row execute function app.set_updated_at();
create trigger audit_rental_drafts after insert or update or delete on rental_drafts for each row execute function app.audit_row();
alter table rental_drafts enable row level security;
create policy admin_all on rental_drafts for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on rental_drafts from anon, authenticated;
grant all on rental_drafts to service_role;

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description) values
  ('finish_rental_draft', 'cs', 'Finish a rental started at pickup', 'high', 'minutes', 120, 'A rental was started with Quick start at pickup (0145): the car is out; finish the renter''s details, the price and the payment, then add it.')
on conflict (task_type) do nothing;

-- the people who enter rentals and offers
create or replace function app.may_draft(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce(app.user_is_admin(p_user), false) or coalesce(app.user_is_staff(p_user), false) or coalesce(app.user_is_field(p_user), false)
$$;

-- what is still missing, in words, for the list
create or replace function app.draft_missing(p_kind text, d jsonb) returns text[]
language sql immutable as $$
  select array_remove(array[
    case when coalesce(d #>> '{f,vehicle_id}', d ->> 'vehicle_id', '') = '' then 'the car' end,
    case when coalesce(d #>> '{f,pickup_at}', d ->> 'pickup_at', '') = '' or coalesce(d #>> '{f,return_at}', d ->> 'return_at', '') = '' then 'the dates' end,
    case when coalesce(d ->> 'renter_id', '') = '' and coalesce(d #>> '{f,full_name}', d ->> 'full_name', '') = '' then 'the renter' end,
    case when coalesce(d ->> 'renter_id', '') = '' and coalesce(d #>> '{f,email}', d ->> 'email', '') = '' then 'the renter''s email' end,
    case when coalesce(d ->> 'renter_id', '') = '' and coalesce(d #>> '{f,date_of_birth}', d ->> 'date_of_birth', '') = '' then 'the date of birth' end,
    case when p_kind = 'rental' and coalesce(d ->> 'paid_by', '') = '' then 'how it is paid' end], null)
$$;

-- p: {id (to update), kind, data, title, hold (boolean), quick}. Nothing in data is required.
create or replace function app.draft_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  d rental_drafts;
  v_kind text := coalesce(nullif(p ->> 'kind', ''), 'rental');
  v_data jsonb := coalesce(p -> 'data', '{}'::jsonb);
  v_car uuid;
  v_hold boolean := coalesce((p ->> 'hold')::boolean, false);
  v_block uuid;
begin
  if not app.may_draft(p_by) then raise exception 'Staff save drafts' using errcode = '42501'; end if;
  if v_kind not in ('rental', 'offer') then raise exception 'A draft is a rental or an offer' using errcode = '22023'; end if;
  if jsonb_typeof(v_data) <> 'object' then raise exception 'The draft is a form' using errcode = '22023'; end if;
  if pg_column_size(v_data) > 200000 then raise exception 'The draft is too large' using errcode = '22023'; end if;
  begin v_car := nullif(coalesce(v_data #>> '{f,vehicle_id}', v_data ->> 'vehicle_id'), '')::uuid; exception when others then v_car := null; end;
  if v_car is not null and not exists (select 1 from vehicles v where v.id = v_car) then v_car := null; end if;
  if nullif(p ->> 'id', '') is not null then
    select * into d from rental_drafts where id = (p ->> 'id')::uuid for update;
    if d.id is null then raise exception 'That draft is gone: it was finished or discarded' using errcode = 'P0002'; end if;
    if d.status <> 'open' then raise exception 'That draft is %: start a new one', d.status using errcode = '23514'; end if;
    if d.created_by <> p_by and not app.user_is_admin(p_by) and not app.may_draft(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
    update rental_drafts set data = v_data, title = nullif(btrim(coalesce(p ->> 'title', '')), ''), vehicle_id = v_car, updated_by = p_by,
           quick = quick or coalesce((p ->> 'quick')::boolean, false)
     where id = d.id returning * into d;
  else
    insert into rental_drafts (kind, created_by, updated_by, data, title, vehicle_id, quick)
    values (v_kind, p_by, p_by, v_data, nullif(btrim(coalesce(p ->> 'title', '')), ''), v_car, coalesce((p ->> 'quick')::boolean, false))
    returning * into d;
  end if;
  -- the hold: a calendar block of two hours on the car, renewed while the draft is saved; moved when the car changes
  if d.hold_block_id is not null and (not v_hold or v_car is distinct from (select k.vehicle_id from vehicle_calendar_blocks k where k.id = d.hold_block_id)) then
    update vehicle_calendar_blocks set removed_at = now(), removed_by = p_by, removed_reason = 'The draft no longer holds this car'
     where id = d.hold_block_id and removed_at is null;
    update rental_drafts set hold_block_id = null where id = d.id returning * into d;
  end if;
  if v_hold and v_car is not null then
    if d.hold_block_id is null then
      insert into vehicle_calendar_blocks (vehicle_id, reason, starts_at, ends_at, note, created_by, source)
      values (v_car, 'admin', now(), now() + interval '2 hours', format('Held for a rental being entered by %s', (select coalesce(u.full_name, u.email) from users u where u.id = p_by)), p_by, 'staff')
      returning id into v_block;
      update rental_drafts set hold_block_id = v_block where id = d.id returning * into d;
    else
      update vehicle_calendar_blocks set ends_at = greatest(ends_at, now() + interval '2 hours') where id = d.hold_block_id and removed_at is null;
    end if;
  end if;
  if d.quick then
    perform app.raise_task(p_type => 'finish_rental_draft', p_title => format('Finish the rental started at pickup%s', coalesce(': ' || d.title, '')),
      p_detail => 'Open Bookings, Add a rental, Unfinished rentals, and finish it: the renter''s details, the price and the payment.',
      p_vehicle => v_car, p_related_table => 'rental_drafts', p_related_id => d.id, p_created_by => p_by, p_dedupe => 'finish_rental_draft:' || d.id);
  end if;
  return jsonb_build_object('id', d.id, 'kind', d.kind, 'updated_at', d.updated_at, 'held', d.hold_block_id is not null,
    'hold_until', (select k.ends_at from vehicle_calendar_blocks k where k.id = d.hold_block_id), 'missing', to_jsonb(app.draft_missing(d.kind, d.data)));
end $$;

create or replace function app.draft_close(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  d rental_drafts;
  v_status text := case when coalesce(p ->> 'status', 'done') = 'discarded' then 'discarded' else 'done' end;
begin
  if not app.may_draft(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into d from rental_drafts where id = (p ->> 'id')::uuid for update;
  if d.id is null then return jsonb_build_object('ok', true, 'gone', true); end if;
  update rental_drafts set status = v_status, finished_at = now(), updated_by = p_by,
         booking_id = coalesce((select b.id from bookings b where b.id::text = p ->> 'booking' or b.booking_number = p ->> 'booking'), booking_id)
   where id = d.id;
  update vehicle_calendar_blocks set removed_at = now(), removed_by = p_by, removed_reason = case v_status when 'done' then 'The rental was added' else 'The draft was discarded' end
   where id = d.hold_block_id and removed_at is null;
  update tasks set status = 'done', completed_at = now(), completed_by = p_by where dedupe_key = 'finish_rental_draft:' || d.id and status in ('open', 'in_progress', 'waiting');
  return jsonb_build_object('ok', true, 'status', v_status);
end $$;

-- the open drafts: one's own, and (staff) everyone's, newest first
create or replace function app.drafts_list(p_by uuid, p jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'title', d.title, 'quick', d.quick, 'updated_at', d.updated_at, 'created_at', d.created_at,
           'by', (select coalesce(u.full_name, u.email) from users u where u.id = d.created_by), 'mine', d.created_by = p_by,
           'vehicle', case when d.vehicle_id is not null then app.vehicle_name(d.vehicle_id) end,
           'held_until', (select k.ends_at from vehicle_calendar_blocks k where k.id = d.hold_block_id and k.removed_at is null and k.ends_at > now()),
           'missing', to_jsonb(app.draft_missing(d.kind, d.data))) order by d.updated_at desc), '[]'::jsonb)
    from rental_drafts d
   where app.may_draft(p_by) and d.status = 'open' and (nullif(p ->> 'kind', '') is null or d.kind = p ->> 'kind')
     and (d.created_by = p_by or not coalesce((p ->> 'mine')::boolean, false))
     and d.updated_at > now() - interval '30 days'
$$;
create or replace function app.draft_get(p_by uuid, p jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', d.id, 'kind', d.kind, 'data', d.data, 'title', d.title, 'quick', d.quick, 'status', d.status, 'updated_at', d.updated_at,
           'held', d.hold_block_id is not null and exists (select 1 from vehicle_calendar_blocks k where k.id = d.hold_block_id and k.removed_at is null and k.ends_at > now()))
    from rental_drafts d where d.id = (p ->> 'id')::uuid and app.may_draft(p_by)
$$;

-- a rental added from a quick start: the readings taken at pickup go on it; the draft is finished
alter function app.manual_rental_create(uuid, jsonb) rename to manual_rental_create_pre0145;
create or replace function app.manual_rental_create(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_out jsonb;
  v_id uuid;
begin
  -- the draft's own hold is not a clash: lifted first (put back if the rental cannot be added, as all of this is one transaction)
  if nullif(p ->> 'draft_id', '') is not null then
    update vehicle_calendar_blocks k set removed_at = now(), removed_by = p_by, removed_reason = 'The rental was added'
      from rental_drafts d where d.id = (p ->> 'draft_id')::uuid and k.id = d.hold_block_id and k.removed_at is null;
  end if;
  v_out := app.manual_rental_create_pre0145(p_by, p - 'draft_id' - 'odometer_out_km' - 'fuel_out_pct');
  v_id := (v_out ->> 'booking_id')::uuid;
  if nullif(p ->> 'odometer_out_km', '') is not null or nullif(p ->> 'fuel_out_pct', '') is not null then
    update bookings set odometer_out_km = coalesce(nullif(p ->> 'odometer_out_km', '')::integer, odometer_out_km),
                        fuel_out_pct = coalesce(least(greatest(nullif(p ->> 'fuel_out_pct', '')::integer, 0), 100)::smallint, fuel_out_pct)
     where id = v_id;
  end if;
  if nullif(p ->> 'draft_id', '') is not null then
    perform app.draft_close(p_by, jsonb_build_object('id', p ->> 'draft_id', 'status', 'done', 'booking', v_id));
  end if;
  return v_out;
end $$;


-- ================================================================ 2. a long rental's periods, each with its agreement
-- A rental longer than one period (app.rental_periods, 0139) has a row per period. The first is covered by the
-- booking's agreement. Each later one gets a new version of the agreement (CarmaCars' and Blind Spot's) made
-- long_rental_agreement_lead_days before it starts and sent to the renter to sign; what is due for that period is
-- shown with it (the renter pays from the portal's Balance due, or staff take it). The agreement of the period before is
-- kept as superseded (never voided: it was signed and it covered its days).
create table if not exists booking_periods (
  id            uuid primary key default gen_random_uuid(),
  booking_id    uuid not null references bookings (id) on delete cascade,
  seq           integer not null check (seq >= 1),
  starts_at     timestamptz not null,
  ends_at       timestamptz not null check (ends_at > starts_at),
  days          integer not null check (days >= 1),
  amount_cents  bigint not null default 0,
  status        text not null default 'upcoming' check (status in ('upcoming', 'opening', 'issued', 'cancelled')),
  send_after    timestamptz,
  agreement_id  uuid references rental_agreements (id),
  issued_at     timestamptz,
  attempts      integer not null default 0,
  last_error    text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (booking_id, seq)
);
comment on table booking_periods is 'The periods of a long rental (0145): each later period has its own version of the rental agreement, made long_rental_agreement_lead_days before it starts, and what is due for it.';
create trigger booking_periods_updated before update on booking_periods for each row execute function app.set_updated_at();
create trigger audit_booking_periods after insert or update or delete on booking_periods for each row execute function app.audit_row();
alter table booking_periods enable row level security;
create policy admin_all on booking_periods for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on booking_periods from anon, authenticated;
grant all on booking_periods to service_role;

alter table rental_agreements add column if not exists period_seq integer;
comment on column rental_agreements.period_seq is 'The period of a long rental this version of the agreement covers (0145); null: the whole booking, or its first period.';
alter table rental_agreements drop constraint if exists rental_agreements_status_check;
alter table rental_agreements add constraint rental_agreements_status_check check (status in ('open', 'signed', 'completed', 'voided', 'superseded'));
comment on column rental_agreements.status is 'open, signed, completed, voided; superseded (0145): the version of an earlier period of a long rental, replaced by the next period''s.';

-- the periods of a booking, kept in step with its dates (periods already sent stay as they are)
create or replace function app.booking_periods_sync(p_booking uuid) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  r record;
  v_n integer;
  v_total bigint;
  v_sum bigint := 0;
  v_amt bigint;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return 0; end if;
  if b.status::text in ('cancelled', 'declined', 'expired') then
    update booking_periods set status = 'cancelled' where booking_id = p_booking and status in ('upcoming', 'opening');
    return 0;
  end if;
  select count(*) into v_n from app.rental_periods(b.pickup_at, b.return_at);
  if coalesce(v_n, 0) <= 1 then
    delete from booking_periods where booking_id = p_booking and status in ('upcoming', 'cancelled');
    return 0;
  end if;
  v_total := coalesce(b.renter_due_at_booking_cents, b.total_due_at_booking_cents, 0);
  for r in select * from app.rental_periods(b.pickup_at, b.return_at) loop
    v_amt := case when r.seq = v_n then v_total - v_sum else round(v_total::numeric * r.days / greatest(b.billable_days, 1))::bigint end;
    v_sum := v_sum + v_amt;
    insert into booking_periods (booking_id, seq, starts_at, ends_at, days, amount_cents, status, issued_at)
    values (p_booking, r.seq, r.starts_at, r.ends_at, r.days, v_amt, case when r.seq = 1 then 'issued' else 'upcoming' end, case when r.seq = 1 then now() end)
    on conflict (booking_id, seq) do update set starts_at = excluded.starts_at, ends_at = excluded.ends_at, days = excluded.days, amount_cents = excluded.amount_cents,
      status = case when booking_periods.status = 'cancelled' then 'upcoming' else booking_periods.status end
     where booking_periods.status in ('upcoming', 'cancelled') or booking_periods.seq = 1;
  end loop;
  delete from booking_periods where booking_id = p_booking and seq > v_n and status in ('upcoming', 'cancelled');
  return v_n;
end $$;

create or replace function app.booking_periods_trg() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if tg_op = 'INSERT' or new.pickup_at is distinct from old.pickup_at or new.return_at is distinct from old.return_at or new.status is distinct from old.status
     or new.renter_due_at_booking_cents is distinct from old.renter_due_at_booking_cents then
    if new.return_at - new.pickup_at > interval '27 days' or exists (select 1 from booking_periods bp where bp.booking_id = new.id) then
      perform app.booking_periods_sync(new.id);
    end if;
  end if;
  return null;
end $$;
drop trigger if exists booking_periods_sync on bookings;
create trigger booking_periods_sync after insert or update on bookings for each row execute function app.booking_periods_trg();
-- the long rentals already on the books
do $$ declare b record; begin
  for b in select id from bookings where return_at - pickup_at > interval '27 days' and status::text in ('confirmed', 'on_rent', 'pending_payment') loop
    perform app.booking_periods_sync(b.id);
  end loop;
end $$;

-- a booking whose next period is being opened signs like a rental added by staff (its agreement opened by the site,
-- completed on the renter's signature), whatever the way it was booked
create or replace function app.booking_added_live(b bookings) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce(b.added_by_staff and (b.status = 'confirmed' or (b.status = 'on_rent' and b.added_mode = 'in_progress')), false)
      or (b.status::text in ('confirmed', 'on_rent') and exists (select 1 from booking_periods bp where bp.booking_id = b.id and bp.seq > 1 and bp.status in ('opening', 'issued')))
$$;

-- the periods whose agreement is due: lead days before the start (or sent now by staff)
create or replace function public.server_periods_due(p_limit integer default 5) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(x), '[]'::jsonb) from (
    select bp.booking_id, bp.seq, b.booking_number, r.user_id as renter_user_id
      from booking_periods bp join bookings b on b.id = bp.booking_id join renters r on r.id = b.renter_id
     where bp.seq > 1 and bp.status in ('upcoming', 'opening') and bp.attempts < 3
       and coalesce(bp.send_after, bp.starts_at - make_interval(days => coalesce((app.settings()).long_rental_agreement_lead_days, 3))) <= now()
       and b.status::text in ('confirmed', 'on_rent') and r.user_id is not null
       and not coalesce(b.agreement_on_paper, false) and not coalesce(b.do_not_email, false)
       and not exists (select 1 from booking_periods e where e.booking_id = bp.booking_id and e.seq < bp.seq and e.status in ('upcoming', 'opening'))
     order by bp.starts_at limit greatest(coalesce(p_limit, 5), 1)) x
$$;

-- before the site makes the next period's agreement: the period before is superseded, the number gets the period
create or replace function public.server_period_begin(p_booking uuid, p_seq integer) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  bp booking_periods;
  v_base text;
begin
  select * into b from bookings where id = p_booking for update;
  select * into bp from booking_periods where booking_id = p_booking and seq = p_seq for update;
  if b.id is null or bp.id is null then raise exception 'That period is gone' using errcode = 'P0002'; end if;
  if bp.status = 'issued' then return jsonb_build_object('ok', true, 'already', true); end if;
  if bp.status = 'cancelled' then raise exception 'That period was cancelled' using errcode = '23514'; end if;
  update rental_agreements set status = 'superseded' where booking_id = p_booking and status = 'completed';
  update rental_agreements set status = 'voided', voided_at = now(), void_reason = format('Replaced by the agreement for period %s', p_seq)
   where booking_id = p_booking and status in ('open', 'signed');
  v_base := coalesce(regexp_replace(b.agreement_number, '-P[0-9]+$', ''), 'RA-' || nextval('rental_agreement_number_seq'));
  update bookings set agreement_number = v_base || '-P' || p_seq where id = p_booking;
  update booking_periods set status = 'opening' where id = bp.id;
  return jsonb_build_object('ok', true, 'agreement_number', v_base || '-P' || p_seq);
end $$;

-- after: the period knows its agreement; the renter is told (sign, and what is due); a miss is retried, then a task
create or replace function public.server_period_done(p_booking uuid, p_seq integer, p_ok boolean, p_error text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  bp booking_periods;
  a rental_agreements;
  v_due bigint;
begin
  select * into b from bookings where id = p_booking;
  select * into bp from booking_periods where booking_id = p_booking and seq = p_seq for update;
  if bp.id is null then return jsonb_build_object('ok', false); end if;
  if not p_ok then
    update booking_periods set attempts = attempts + 1, last_error = left(p_error, 500) where id = bp.id returning * into bp;
    if bp.attempts >= 3 then
      perform app.raise_task(p_type => 'paper_agreement_scan', p_title => format('Booking %s: the agreement for period %s could not be made by itself. Open the booking and press Sign now, or record it on paper', b.booking_number, p_seq),
        p_booking => p_booking, p_renter => b.renter_id, p_dedupe => 'period_agreement_failed:' || bp.id);
    end if;
    return jsonb_build_object('ok', false);
  end if;
  select * into a from rental_agreements where booking_id = p_booking and status in ('open', 'signed', 'completed') order by opened_at desc limit 1;
  update rental_agreements set period_seq = p_seq where id = a.id;
  update booking_periods set status = 'issued', issued_at = now(), agreement_id = a.id, last_error = null where id = bp.id;
  perform public.server_agreement_auto_done(p_booking, true, null, 'period');
  v_due := least(greatest(app.booking_part_open(p_booking, 'balance'), 0), bp.amount_cents);
  perform app.log_booking_event(p_booking, 'adjusted', b.status::text, b.status::text, null,
    format('Period %s (%s to %s): its rental agreement made and sent to sign%s', p_seq, app.fmt_datetime(bp.starts_at), app.fmt_datetime(bp.ends_at),
           case when v_due > 0 then format('; %s due for it', app.fmt_money(v_due)) else '' end), null, 'system',
    jsonb_build_object('period', p_seq, 'agreement_id', a.id, 'due_cents', v_due));
  return jsonb_build_object('ok', true, 'agreement_id', a.id, 'due_cents', v_due);
end $$;

-- the agreement says which period it covers
alter function public.server_agreement_facts(uuid, uuid) rename to server_agreement_facts_pre0145;
create or replace function public.server_agreement_facts(p_booking uuid, p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := public.server_agreement_facts_pre0145(p_booking, p_by);
  bp booking_periods;
  v_n integer;
begin
  select count(*) into v_n from booking_periods where booking_id = p_booking and status <> 'cancelled';
  if coalesce(v_n, 0) <= 1 then return v || jsonb_build_object('period', null); end if;
  select * into bp from booking_periods where booking_id = p_booking and status in ('opening', 'issued') order by seq desc limit 1;
  return v || jsonb_build_object('period', jsonb_build_object('seq', bp.seq, 'of', v_n, 'starts_at', bp.starts_at, 'ends_at', bp.ends_at, 'days', bp.days,
    'amount_cents', bp.amount_cents, 'agreement_lead_days', (app.settings()).long_rental_agreement_lead_days));
end $$;

-- the job runs while a period is due
alter function app.server_jobs_due() rename to server_jobs_due_pre0145;
create or replace function app.server_jobs_due() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.server_jobs_due_pre0145() || jsonb_build_object('agreements', coalesce((app.server_jobs_due_pre0145() ->> 'agreements')::boolean, false)
    or jsonb_array_length(public.server_periods_due(1)) > 0)
$$;

-- staff: the periods of a booking, and sending the next agreement now
create or replace function app.booking_periods_list(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_id uuid := (select b.id from bookings b where b.id::text = p ->> 'booking' or b.booking_number = upper(btrim(coalesce(p ->> 'booking', ''))));
begin
  if not (app.user_is_admin(p_by) or app.user_is_staff(p_by)) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('seq', bp.seq, 'starts_at', bp.starts_at, 'ends_at', bp.ends_at, 'days', bp.days, 'amount_cents', bp.amount_cents,
      'status', bp.status, 'issued_at', bp.issued_at, 'attempts', bp.attempts, 'last_error', bp.last_error,
      'sends_on', case when bp.status = 'upcoming' then coalesce(bp.send_after, bp.starts_at - make_interval(days => coalesce((app.settings()).long_rental_agreement_lead_days, 3))) end,
      'agreement', (select jsonb_build_object('number', a.agreement_number, 'status', a.status, 'signed_at', a.renter_signed_at) from rental_agreements a
                     where a.id = bp.agreement_id or (bp.seq = 1 and bp.agreement_id is null and a.booking_id = bp.booking_id and coalesce(a.period_seq, 1) = 1 and a.status <> 'voided')
                     order by a.opened_at desc limit 1)) order by bp.seq)
    from booking_periods bp where bp.booking_id = v_id), '[]'::jsonb);
end $$;
create or replace function app.booking_period_send_now(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid := (select b.id from bookings b where b.id::text = p ->> 'booking' or b.booking_number = upper(btrim(coalesce(p ->> 'booking', ''))));
  bp booking_periods;
begin
  if not (app.user_is_admin(p_by) or app.user_is_staff(p_by)) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into bp from booking_periods where booking_id = v_id and status = 'upcoming' order by seq limit 1;
  if bp.id is null then raise exception 'No period is waiting for its agreement' using errcode = '23514'; end if;
  update booking_periods set send_after = now(), attempts = 0 where id = bp.id;
  perform app.log_booking_event(v_id, 'adjusted', null, null, null, format('The agreement for period %s is to be sent now', bp.seq), p_by, null, jsonb_build_object('period', bp.seq));
  return jsonb_build_object('ok', true, 'seq', bp.seq);
end $$;

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0145;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if (p_call = 'ops_read' and p_name in ('drafts', 'draft_get', 'booking_periods')) or (p_call = 'ops_do' and p_name in ('draft_save', 'draft_close', 'period_send_now')) then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    p_ := p_ - '_va';
    perform app.door_begin(p_user, p_aal);
    case p_name
    when 'drafts' then return app.drafts_list(p_user, p_);
    when 'draft_get' then return app.draft_get(p_user, p_);
    when 'draft_save' then return app.draft_save(p_user, p_);
    when 'draft_close' then return app.draft_close(p_user, p_);
    when 'booking_periods' then return app.booking_periods_list(p_user, p_);
    when 'period_send_now' then return app.booking_period_send_now(p_user, p_);
    end case;
  end if;
  return app.door_pre0145(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ the guides
-- GUIDES 0145 START (generated by supabase/seed/0145_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('admin', 'partners-company-cars-and-rentals-added-by-hand', 'chapter', 'fleet-and-listings', 'A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.

## Add a car

**Cars** > **Vehicles**, then **Add a car**. Start with the VIN: everything else about the car comes from it.

1. Type or paste the VIN. At the 17th character the car is looked up: one line shows the year, make, model, trim, body, seats, doors, fuel, drive, gearbox and engine. Press Edit only if something is wrong.
2. When the VIN fits several trims, the form asks which trim it is: press the one on the car''s papers or badge, or **Not sure** (Admin > Today asks again).
3. No VIN at hand? Press **No VIN at hand? Add the car by its plate** and choose the year, make and model from the lists. The VIN can be added later; the details fill in then.
4. Tap the colour (it is not in the VIN). Leave it empty and it is read from the cover photo once the car has one.
5. Check the class. It is set from the make, model, body and age (a 2016 Porsche Macan is Premium, an SUV is SUV) and the line under it says why. Change it if it is wrong.
6. Choose who supplies it: **A program owner''s car** (choose the owner; the car starts its onboarding), **CarmaCars-owned (company fleet)** (no owner; all of its revenue is CarmaCars'') or **A partner rental company''s car** (choose the partner; leave the commission empty to use the partner''s).
7. The daily rate is filled in from similar cars, else the class. Keep it, change it, or empty it and set the rates later on the car''s Rates tab. Press **Add the car**.

> Tip: The title, description and features are written by themselves right after the car is added, from the VIN details. Change any of them on the car''s listing; a field you change is kept.

> Good to know: Every car gets a fleet number and its standard settings the moment it is added: a complete rate card (the daily rate you typed or the suggested one, weekend, weekly and monthly from it, the kilometres a day, the extra kilometre rate, the deposit and the delivery and pickup fee of its class) and drivers 18 to 20 allowed. Each value set this way says (Set automatically) on the car''s Overview and Rates tab until you change it. The defaults come from Settings: Program and Fee defaults.

> Tip: A VIN that does not add up (one character misread) shows a warning; you can still save it. A VIN the decoder cannot read asks only the year, make and model and never stops you: the details fill in when it is read later. The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.

The gearbox comes from the government''s fuel economy data for the model when it has one gearbox for it, or from the VIN when the VIN states it. Seats come from the VIN, or the usual number for the body (4 for a coupe or convertible, 5 for a sedan, SUV or hatchback). When either is not certain, Admin > Today shows **Confirm gearbox and seats**: press the gearbox and the number of seats, then **Save**. A car whose VIN fits several trims shows **Pick the trim** there: press the right one. Either way the title, description and search text are written again.

On a car''s page, **Who supplies the car** shows the supplier and the commission, and changes them. Vehicles filters by supply type.

## Partners

**People** > **Partners**. Partner rental companies whose cars we rent out on commission.

1. Press **Add a partner**: business and legal name, contacts, HST number, commission and insurance with its expiry date.
2. Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Staff tasks gets a reminder (Program settings sets how many days before).
3. Banking (Admins only): **Save the payout account** for the account we pay the partner into. The account number is stored encrypted. Press **Verify** once checked.
4. Portal: **Invite to the owner portal** gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.
5. Signed on paper? Press **Print the partner agreement**, then record the signed scan under Record a paper signature.

## A partner fleet on its own rates

Some partners send a price sheet of their own rates instead of sharing what the renter pays. 01 Motors works this way: its whole fleet is on the site, and staff manage its cars (it has no portal sign-in yet; add its email on the partner page and invite it later).

1. **People** > **Partners** > the partner. **Pricing** shows how it is paid: the renter pays the partner''s sheet rate plus the markup (10% unless you set another), rounded to the nearest dollar; CarmaCars keeps the markup plus its cut (20% of the sheet rate); the partner is owed the rest of its sheet rate. Press **Edit pricing** to change the markup, the cut or the basis for every car at once.
2. **Cars** lists each car with its sheet rates a day (1 to 2 days, 3 or more, 7 or more) and the renter''s rates. Press **Edit** on a car to change a negotiated rate, give that car its own markup or cut, mark it **Insurance included** or **No credit card needed**, or confirm its model year. The renter''s rates change at once.
3. The site shows these cars with their tiers (1 to 2 days, 3 to 6 days, 7 days or more) and "Guideline rates; final price confirmed after review". A car with insurance included needs no coverage choice from the renter (coverage option 4, confirmed by itself); a car with no credit card needed takes a debit card for the payment and the deposit. The deposit, the licence and identity checks and the ages stay the same.
4. The price sheet has no years, VINs or plates. Until you confirm the year, the site leaves it out and says "Year confirmed when you book"; an offer waits until the year is confirmed (Edit on the car, Model year). Add the plate and the VIN on the car''s page before its first handover.
5. Real photos: open the car (its name in Cars), **Photos**, and add them. Once approved they replace the eight studio stand-ins.

> Good to know: The partner''s monthly statement shows each rental at the sheet rate, the cut and the payout; never what the renter paid. A refund lowers the partner''s share in proportion; a discount CarmaCars gives comes out of the markup.

## Add a rental by hand

**Bookings** > **Add a rental**. For phone, walk-in, Turo, partner and insurer bookings, the owner using their own car, and placeholders: a rental already agreed. To send an offer instead, use Send an offer.

1. Quick start sets the usual choices in one tap: **Phone**, **Walk-in**, **Turo or another platform**, **Insurance replacement**, **Owner using own car** or **Placeholder**.
2. Choose the car and the dates. The calendar and the price are checked by themselves: clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.
3. The dates decide the case, shown under them (nothing to tick): a pickup ahead is an upcoming rental, handed over at pickup as usual. A pickup already passed with the return ahead is a rental already underway: it is recorded as on trip from the pickup you enter, on any active car (even one closed to public bookings), and anything a handover checks that is still missing (signature, licence check, coverage proof, deposit, condition report, insurance) becomes a task. A return already passed is a rental that has ended: kept as completed, paid another way or unpaid.
4. Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.
5. Check the price: every line of the price can be changed where it stands. Type a new amount in the line (the rental charge for the trip or a rate a day, the young driver fee, the Protection Plan, delivery, each add-on, the deposit, the kilometres a day); HST and the total follow. Add a line from the list or a charge of its own; Remove takes a fee off. The (i) beside each line says what it is and how it is worked out. One optional reason covers all the changes.
6. Any length: the dates may run past 30 days (up to the staff limit in Program settings, 730 days by default). From 30 days the rental charge is the monthly rate for each 30 days, and the monthly periods are listed.
7. A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.
8. An owner''s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner''s car needs its terms (Revenue Share) first. The handover still needs the car on the fleet policy: press **Insurer confirmed** once the insurer confirms it.
9. The rent is paid by: e-Transfer or cash (received), card on file (charged when the renter signs), payment link, platform payout (Turo), insurer billed later, cheque, bank transfer, or unpaid. Paid in parts (some cash, some e-Transfer): press **Add another payment (paid in parts)** and type each amount. Then the deposit, its own way: card hold, cash, e-Transfer (with its reference and date) or no deposit.
10. Before you save checks it all in one box: the renter, the car, the days, the total, what was received and what is still to collect, the deposit and the agreement.
11. The rental agreement: Send it to sign online, or Already signed on paper (a task asks for the scan). The calendar: untick Blocks the car''s calendar for an insurance replacement with dates not known yet, with the reason.
12. Tick **Do not email the renter** if they should not get the confirmation. Press **Add the rental**.

> Tip: The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. On the booking, **Verified in person** records a licence checked at the counter. A rental already underway can be paid by payment link (the renter signs, then pays from their booking) or the saved card, like an upcoming one.

## Retire or delete a car

**Cars** > **Retire or delete**, or the car''s own page.

1. **Retire this car** takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. **Restore** brings it back.
2. **Delete this car** removes a car added by mistake, with its photos. Only a car with nothing tied to money (no confirmed or paid booking, payment, statement, toll or damage). Type the plate or the name to confirm.
3. Booking requests that never confirmed and never took money (requested, offered, declined, expired) do not stop a delete. The confirmation lists them; they are removed with the car and a copy is kept. The renters stay on file.
4. On the same page, **Delete all sample cars** deletes every sample car that meets the rule at once, with its requests. Type DELETE SAMPLE CARS to confirm; the ones kept show why, with the booking numbers.

## Sample cars on the site

**Cars** > **Vehicles**, or **Settings** > **Site**. The 20 example cars the site started with, so the fleet never looks empty while the real cars are listed.

1. **Hide sample cars** asks first ("Hide all 20 sample cars from the site?"); press **Hide them** to take every sample car off the site at once, or **Keep them**. Nothing else stops it: not an enquiry, not an old request.
2. **Show sample cars** puts the 20 back, with their photos and rates. Ones that were deleted are made again.
3. On the site each one is marked "Example car". They never appear in search engines or the sitemap.
4. A request on a sample car is never a booking. When the person picks dates, the car page and the request form show a real car free for them (the same make and model first, else the same class and body at a similar price) with one tap to switch to it. If they keep the sample car, it becomes an enquiry (number EQ-1001 and up) and customer service gets the task Suggest a similar real car, naming the free real car.

> Tip: Hide the sample cars once enough real cars are on the site. Delete all sample cars removes them for good.

## Why a car is not on the site yet

**Cars** > **Vehicles**, the card Not on the site yet.

1. Every real car that is not on the site is listed with its next step first: the rates, Publish now, the listing review.
2. The same car is a line on To do with **Set rates and publish**. The car comes off both once it is on the site.
3. A car without photos is marked sample photos: once listed it shows a sample photo until its real photos are approved.

## Tolls when two rentals overlap

Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.
', 'Partners, company cars and rentals added by hand', 'Add a car, partners, add a rental, retire or delete a car, sample cars and tolls with two rentals.',
  'A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.

## Add a car

**Cars** > **Vehicles**, then **Add a car**. Start with the VIN: everything else about the car comes from it.

1. Type or paste the VIN. At the 17th character the car is looked up: one line shows the year, make, model, trim, body, seats, doors, fuel, drive, gearbox and engine. Press Edit only if something is wrong.
2. When the VIN fits several trims, the form asks which trim it is: press the one on the car''s papers or badge, or **Not sure** (Admin > Today asks again).
3. No VIN at hand? Press **No VIN at hand? Add the car by its plate** and choose the year, make and model from the lists. The VIN can be added later; the details fill in then.
4. Tap the colour (it is not in the VIN). Leave it empty and it is read from the cover photo once the car has one.
5. Check the class. It is set from the make, model, body and age (a 2016 Porsche Macan is Premium, an SUV is SUV) and the line under it says why. Change it if it is wrong.
6. Choose who supplies it: **A program owner''s car** (choose the owner; the car starts its onboarding), **CarmaCars-owned (company fleet)** (no owner; all of its revenue is CarmaCars'') or **A partner rental company''s car** (choose the partner; leave the commission empty to use the partner''s).
7. The daily rate is filled in from similar cars, else the class. Keep it, change it, or empty it and set the rates later on the car''s Rates tab. Press **Add the car**.

> Tip: The title, description and features are written by themselves right after the car is added, from the VIN details. Change any of them on the car''s listing; a field you change is kept.

> Good to know: Every car gets a fleet number and its standard settings the moment it is added: a complete rate card (the daily rate you typed or the suggested one, weekend, weekly and monthly from it, the kilometres a day, the extra kilometre rate, the deposit and the delivery and pickup fee of its class) and drivers 18 to 20 allowed. Each value set this way says (Set automatically) on the car''s Overview and Rates tab until you change it. The defaults come from Settings: Program and Fee defaults.

> Tip: A VIN that does not add up (one character misread) shows a warning; you can still save it. A VIN the decoder cannot read asks only the year, make and model and never stops you: the details fill in when it is read later. The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.

The gearbox comes from the government''s fuel economy data for the model when it has one gearbox for it, or from the VIN when the VIN states it. Seats come from the VIN, or the usual number for the body (4 for a coupe or convertible, 5 for a sedan, SUV or hatchback). When either is not certain, Admin > Today shows **Confirm gearbox and seats**: press the gearbox and the number of seats, then **Save**. A car whose VIN fits several trims shows **Pick the trim** there: press the right one. Either way the title, description and search text are written again.

On a car''s page, **Who supplies the car** shows the supplier and the commission, and changes them. Vehicles filters by supply type.

## Partners

**People** > **Partners**. Partner rental companies whose cars we rent out on commission.

1. Press **Add a partner**: business and legal name, contacts, HST number, commission and insurance with its expiry date.
2. Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Staff tasks gets a reminder (Program settings sets how many days before).
3. Banking (Admins only): **Save the payout account** for the account we pay the partner into. The account number is stored encrypted. Press **Verify** once checked.
4. Portal: **Invite to the owner portal** gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.
5. Signed on paper? Press **Print the partner agreement**, then record the signed scan under Record a paper signature.

## A partner fleet on its own rates

Some partners send a price sheet of their own rates instead of sharing what the renter pays. 01 Motors works this way: its whole fleet is on the site, and staff manage its cars (it has no portal sign-in yet; add its email on the partner page and invite it later).

1. **People** > **Partners** > the partner. **Pricing** shows how it is paid: the renter pays the partner''s sheet rate plus the markup (10% unless you set another), rounded to the nearest dollar; CarmaCars keeps the markup plus its cut (20% of the sheet rate); the partner is owed the rest of its sheet rate. Press **Edit pricing** to change the markup, the cut or the basis for every car at once.
2. **Cars** lists each car with its sheet rates a day (1 to 2 days, 3 or more, 7 or more) and the renter''s rates. Press **Edit** on a car to change a negotiated rate, give that car its own markup or cut, mark it **Insurance included** or **No credit card needed**, or confirm its model year. The renter''s rates change at once.
3. The site shows these cars with their tiers (1 to 2 days, 3 to 6 days, 7 days or more) and "Guideline rates; final price confirmed after review". A car with insurance included needs no coverage choice from the renter (coverage option 4, confirmed by itself); a car with no credit card needed takes a debit card for the payment and the deposit. The deposit, the licence and identity checks and the ages stay the same.
4. The price sheet has no years, VINs or plates. Until you confirm the year, the site leaves it out and says "Year confirmed when you book"; an offer waits until the year is confirmed (Edit on the car, Model year). Add the plate and the VIN on the car''s page before its first handover.
5. Real photos: open the car (its name in Cars), **Photos**, and add them. Once approved they replace the eight studio stand-ins.

> Good to know: The partner''s monthly statement shows each rental at the sheet rate, the cut and the payout; never what the renter paid. A refund lowers the partner''s share in proportion; a discount CarmaCars gives comes out of the markup.

## Add a rental by hand

**Bookings** > **Add a rental**. For phone, walk-in, Turo, partner and insurer bookings, the owner using their own car, and placeholders: a rental already agreed. To send an offer instead, use Send an offer.

1. Standing with the renter at pickup? Press **Start at pickup**: type the renter''s name and phone, choose the car, type the kilometres and the fuel, and press **Hold the car and finish later**. The pickup is now; the car is held for 2 hours (renewed while you work on it) and you get a task to finish the rental.
2. Nothing is required to save: the form is saved as a draft as you type (**Save draft** saves at once). Unfinished rentals, on Bookings and on this page, lists every draft with who started it, when, and what is still missing; Finish it opens it where it was left, on any device. Tick Hold the car while I finish to keep the car off the calendar while you type (2 hours, renewed as you save). Discard drops it and frees the car.
3. Quick start sets the usual choices in one tap: **Phone**, **Walk-in**, **Turo or another platform**, **Insurance replacement**, **Owner using own car** or **Placeholder**.
4. Choose the car and the dates. The calendar and the price are checked by themselves: clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.
5. The dates decide the case, shown under them (nothing to tick): a pickup ahead is an upcoming rental, handed over at pickup as usual. A pickup already passed with the return ahead is a rental already underway: it is recorded as on trip from the pickup you enter, on any active car (even one closed to public bookings), and anything a handover checks that is still missing (signature, licence check, coverage proof, deposit, condition report, insurance) becomes a task. A return already passed is a rental that has ended: kept as completed, paid another way or unpaid.
6. Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.
7. Check the price: every line of the price can be changed where it stands. Type a new amount in the line (the rental charge for the trip or a rate a day, the young driver fee, the Protection Plan, delivery, each add-on, the deposit, the kilometres a day); HST and the total follow. Add a line from the list or a charge of its own; Remove takes a fee off. The (i) beside each line says what it is and how it is worked out. One optional reason covers all the changes.
8. Any length: the dates may run past 30 days (up to the staff limit in Program settings, 730 days by default). From 30 days the rental charge is the monthly rate for each 30 days, and the monthly periods are listed. On the booking, Monthly periods shows each period: its share, and its own version of the agreement (CarmaCars'' and Blind Spot''s), sent to the renter to sign a few days before it starts (Program settings: long_rental_agreement_lead_days, 3 by default), with what is due for it on the renter''s Balance due.
9. A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.
10. An owner''s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner''s car needs its terms (Revenue Share) first. The handover still needs the car on the fleet policy: press **Insurer confirmed** once the insurer confirms it.
11. The rent is paid by: e-Transfer or cash (received), card on file (charged when the renter signs), payment link, platform payout (Turo), insurer billed later, cheque, bank transfer, or unpaid. Paid in parts (some cash, some e-Transfer): press **Add another payment (paid in parts)** and type each amount. Then the deposit, its own way: card hold, cash, e-Transfer (with its reference and date) or no deposit.
12. Before you save checks it all in one box: the renter, the car, the days, the total, what was received and what is still to collect, the deposit and the agreement.
13. The rental agreement: Send it to sign online, or Already signed on paper (a task asks for the scan). The calendar: untick Blocks the car''s calendar for an insurance replacement with dates not known yet, with the reason.
14. Tick **Do not email the renter** if they should not get the confirmation. Press **Add the rental**.

> Tip: The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. On the booking, **Verified in person** records a licence checked at the counter. A rental already underway can be paid by payment link (the renter signs, then pays from their booking) or the saved card, like an upcoming one.

## Retire or delete a car

**Cars** > **Retire or delete**, or the car''s own page.

1. **Retire this car** takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. **Restore** brings it back.
2. **Delete this car** removes a car added by mistake, with its photos. Only a car with nothing tied to money (no confirmed or paid booking, payment, statement, toll or damage). Type the plate or the name to confirm.
3. Booking requests that never confirmed and never took money (requested, offered, declined, expired) do not stop a delete. The confirmation lists them; they are removed with the car and a copy is kept. The renters stay on file.
4. On the same page, **Delete all sample cars** deletes every sample car that meets the rule at once, with its requests. Type DELETE SAMPLE CARS to confirm; the ones kept show why, with the booking numbers.

## Sample cars on the site

**Cars** > **Vehicles**, or **Settings** > **Site**. The 20 example cars the site started with, so the fleet never looks empty while the real cars are listed.

1. **Hide sample cars** asks first ("Hide all 20 sample cars from the site?"); press **Hide them** to take every sample car off the site at once, or **Keep them**. Nothing else stops it: not an enquiry, not an old request.
2. **Show sample cars** puts the 20 back, with their photos and rates. Ones that were deleted are made again.
3. On the site each one is marked "Example car". They never appear in search engines or the sitemap.
4. A request on a sample car is never a booking. When the person picks dates, the car page and the request form show a real car free for them (the same make and model first, else the same class and body at a similar price) with one tap to switch to it. If they keep the sample car, it becomes an enquiry (number EQ-1001 and up) and customer service gets the task Suggest a similar real car, naming the free real car.

> Tip: Hide the sample cars once enough real cars are on the site. Delete all sample cars removes them for good.

## Why a car is not on the site yet

**Cars** > **Vehicles**, the card Not on the site yet.

1. Every real car that is not on the site is listed with its next step first: the rates, Publish now, the listing review.
2. The same car is a line on To do with **Set rates and publish**. The car comes off both once it is on the site.
3. A car without photos is marked sample photos: once listed it shows a sample photo until its real photos are approved.

## Tolls when two rentals overlap

Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.
',
  '<p class="gd-p">A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.</p><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-add-a-car" data-gd-task><h2 class="gd-h2">Add a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, then <b class="gd-ui">Add a car</b>. Start with the VIN: everything else about the car comes from it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type or paste the VIN. At the 17th character the car is looked up: one line shows the year, make, model, trim, body, seats, doors, fuel, drive, gearbox and engine. Press Edit only if something is wrong.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">When the VIN fits several trims, the form asks which trim it is: press the one on the car&#39;s papers or badge, or <b class="gd-ui">Not sure</b> (Admin &gt; Today asks again).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">No VIN at hand? Press <b class="gd-ui">No VIN at hand? Add the car by its plate</b> and choose the year, make and model from the lists. The VIN can be added later; the details fill in then.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Tap the colour (it is not in the VIN). Leave it empty and it is read from the cover photo once the car has one.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Check the class. It is set from the make, model, body and age (a 2016 Porsche Macan is Premium, an SUV is SUV) and the line under it says why. Change it if it is wrong.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Choose who supplies it: <b class="gd-ui">A program owner&#39;s car</b> (choose the owner; the car starts its onboarding), <b class="gd-ui">CarmaCars-owned (company fleet)</b> (no owner; all of its revenue is CarmaCars&#39;) or <b class="gd-ui">A partner rental company&#39;s car</b> (choose the partner; leave the commission empty to use the partner&#39;s).</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">The daily rate is filled in from similar cars, else the class. Keep it, change it, or empty it and set the rates later on the car&#39;s Rates tab. Press <b class="gd-ui">Add the car</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The title, description and features are written by themselves right after the car is added, from the VIN details. Change any of them on the car&#39;s listing; a field you change is kept.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Every car gets a fleet number and its standard settings the moment it is added: a complete rate card (the daily rate you typed or the suggested one, weekend, weekly and monthly from it, the kilometres a day, the extra kilometre rate, the deposit and the delivery and pickup fee of its class) and drivers 18 to 20 allowed. Each value set this way says (Set automatically) on the car&#39;s Overview and Rates tab until you change it. The defaults come from Settings: Program and Fee defaults.</div></aside><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A VIN that does not add up (one character misread) shows a warning; you can still save it. A VIN the decoder cannot read asks only the year, make and model and never stops you: the details fill in when it is read later. The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.</div></aside><p class="gd-p">The gearbox comes from the government&#39;s fuel economy data for the model when it has one gearbox for it, or from the VIN when the VIN states it. Seats come from the VIN, or the usual number for the body (4 for a coupe or convertible, 5 for a sedan, SUV or hatchback). When either is not certain, Admin &gt; Today shows <b class="gd-ui">Confirm gearbox and seats</b>: press the gearbox and the number of seats, then <b class="gd-ui">Save</b>. A car whose VIN fits several trims shows <b class="gd-ui">Pick the trim</b> there: press the right one. Either way the title, description and search text are written again.</p><p class="gd-p">On a car&#39;s page, <b class="gd-ui">Who supplies the car</b> shows the supplier and the commission, and changes them. Vehicles filters by supply type.</p></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-partners" data-gd-task><h2 class="gd-h2">Partners</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Partners</b>. Partner rental companies whose cars we rent out on commission.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Add a partner</b>: business and legal name, contacts, HST number, commission and insurance with its expiry date.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Staff tasks gets a reminder (Program settings sets how many days before).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Banking (Admins only): <b class="gd-ui">Save the payout account</b> for the account we pay the partner into. The account number is stored encrypted. Press <b class="gd-ui">Verify</b> once checked.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Portal: <b class="gd-ui">Invite to the owner portal</b> gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Signed on paper? Press <b class="gd-ui">Print the partner agreement</b>, then record the signed scan under Record a paper signature.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-a-partner-fleet-on-its-own-rates" data-gd-task><h2 class="gd-h2">A partner fleet on its own rates</h2><p class="gd-p">Some partners send a price sheet of their own rates instead of sharing what the renter pays. 01 Motors works this way: its whole fleet is on the site, and staff manage its cars (it has no portal sign-in yet; add its email on the partner page and invite it later).</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Partners</b> &gt; the partner. <b class="gd-ui">Pricing</b> shows how it is paid: the renter pays the partner&#39;s sheet rate plus the markup (10% unless you set another), rounded to the nearest dollar; CarmaCars keeps the markup plus its cut (20% of the sheet rate); the partner is owed the rest of its sheet rate. Press <b class="gd-ui">Edit pricing</b> to change the markup, the cut or the basis for every car at once.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Cars</b> lists each car with its sheet rates a day (1 to 2 days, 3 or more, 7 or more) and the renter&#39;s rates. Press <b class="gd-ui">Edit</b> on a car to change a negotiated rate, give that car its own markup or cut, mark it <b class="gd-ui">Insurance included</b> or <b class="gd-ui">No credit card needed</b>, or confirm its model year. The renter&#39;s rates change at once.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The site shows these cars with their tiers (1 to 2 days, 3 to 6 days, 7 days or more) and &quot;Guideline rates; final price confirmed after review&quot;. A car with insurance included needs no coverage choice from the renter (coverage option 4, confirmed by itself); a car with no credit card needed takes a debit card for the payment and the deposit. The deposit, the licence and identity checks and the ages stay the same.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The price sheet has no years, VINs or plates. Until you confirm the year, the site leaves it out and says &quot;Year confirmed when you book&quot;; an offer waits until the year is confirmed (Edit on the car, Model year). Add the plate and the VIN on the car&#39;s page before its first handover.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Real photos: open the car (its name in Cars), <b class="gd-ui">Photos</b>, and add them. Once approved they replace the eight studio stand-ins.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The partner&#39;s monthly statement shows each rental at the sheet rate, the cut and the payout; never what the renter paid. A refund lowers the partner&#39;s share in proportion; a discount CarmaCars gives comes out of the markup.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-add-a-rental-by-hand" data-gd-task><h2 class="gd-h2">Add a rental by hand</h2><p class="gd-p"><b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Add a rental</b>. For phone, walk-in, Turo, partner and insurer bookings, the owner using their own car, and placeholders: a rental already agreed. To send an offer instead, use Send an offer.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Standing with the renter at pickup? Press <b class="gd-ui">Start at pickup</b>: type the renter&#39;s name and phone, choose the car, type the kilometres and the fuel, and press <b class="gd-ui">Hold the car and finish later</b>. The pickup is now; the car is held for 2 hours (renewed while you work on it) and you get a task to finish the rental.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Nothing is required to save: the form is saved as a draft as you type (<b class="gd-ui">Save draft</b> saves at once). Unfinished rentals, on Bookings and on this page, lists every draft with who started it, when, and what is still missing; Finish it opens it where it was left, on any device. Tick Hold the car while I finish to keep the car off the calendar while you type (2 hours, renewed as you save). Discard drops it and frees the car.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Quick start sets the usual choices in one tap: <b class="gd-ui">Phone</b>, <b class="gd-ui">Walk-in</b>, <b class="gd-ui">Turo or another platform</b>, <b class="gd-ui">Insurance replacement</b>, <b class="gd-ui">Owner using own car</b> or <b class="gd-ui">Placeholder</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Choose the car and the dates. The calendar and the price are checked by themselves: clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The dates decide the case, shown under them (nothing to tick): a pickup ahead is an upcoming rental, handed over at pickup as usual. A pickup already passed with the return ahead is a rental already underway: it is recorded as on trip from the pickup you enter, on any active car (even one closed to public bookings), and anything a handover checks that is still missing (signature, licence check, coverage proof, deposit, condition report, insurance) becomes a task. A return already passed is a rental that has ended: kept as completed, paid another way or unpaid.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Check the price: every line of the price can be changed where it stands. Type a new amount in the line (the rental charge for the trip or a rate a day, the young driver fee, the Protection Plan, delivery, each add-on, the deposit, the kilometres a day); HST and the total follow. Add a line from the list or a charge of its own; Remove takes a fee off. The (i) beside each line says what it is and how it is worked out. One optional reason covers all the changes.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Any length: the dates may run past 30 days (up to the staff limit in Program settings, 730 days by default). From 30 days the rental charge is the monthly rate for each 30 days, and the monthly periods are listed. On the booking, Monthly periods shows each period: its share, and its own version of the agreement (CarmaCars&#39; and Blind Spot&#39;s), sent to the renter to sign a few days before it starts (Program settings: long_rental_agreement_lead_days, 3 by default), with what is due for it on the renter&#39;s Balance due.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">An owner&#39;s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner&#39;s car needs its terms (Revenue Share) first. The handover still needs the car on the fleet policy: press <b class="gd-ui">Insurer confirmed</b> once the insurer confirms it.</div></li><li><span class="gd-n" aria-hidden="true">11</span><div class="gd-t">The rent is paid by: e-Transfer or cash (received), card on file (charged when the renter signs), payment link, platform payout (Turo), insurer billed later, cheque, bank transfer, or unpaid. Paid in parts (some cash, some e-Transfer): press <b class="gd-ui">Add another payment (paid in parts)</b> and type each amount. Then the deposit, its own way: card hold, cash, e-Transfer (with its reference and date) or no deposit.</div></li><li><span class="gd-n" aria-hidden="true">12</span><div class="gd-t">Before you save checks it all in one box: the renter, the car, the days, the total, what was received and what is still to collect, the deposit and the agreement.</div></li><li><span class="gd-n" aria-hidden="true">13</span><div class="gd-t">The rental agreement: Send it to sign online, or Already signed on paper (a task asks for the scan). The calendar: untick Blocks the car&#39;s calendar for an insurance replacement with dates not known yet, with the reason.</div></li><li><span class="gd-n" aria-hidden="true">14</span><div class="gd-t">Tick <b class="gd-ui">Do not email the renter</b> if they should not get the confirmation. Press <b class="gd-ui">Add the rental</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. On the booking, <b class="gd-ui">Verified in person</b> records a licence checked at the counter. A rental already underway can be paid by payment link (the renter signs, then pays from their booking) or the saved card, like an upcoming one.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-retire-or-delete-a-car" data-gd-task><h2 class="gd-h2">Retire or delete a car</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Retire or delete</b>, or the car&#39;s own page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Retire this car</b> takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. <b class="gd-ui">Restore</b> brings it back.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Delete this car</b> removes a car added by mistake, with its photos. Only a car with nothing tied to money (no confirmed or paid booking, payment, statement, toll or damage). Type the plate or the name to confirm.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Booking requests that never confirmed and never took money (requested, offered, declined, expired) do not stop a delete. The confirmation lists them; they are removed with the car and a copy is kept. The renters stay on file.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On the same page, <b class="gd-ui">Delete all sample cars</b> deletes every sample car that meets the rule at once, with its requests. Type DELETE SAMPLE CARS to confirm; the ones kept show why, with the booking numbers.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-sample-cars-on-the-site" data-gd-task><h2 class="gd-h2">Sample cars on the site</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, or <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Site</b>. The 20 example cars the site started with, so the fleet never looks empty while the real cars are listed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Hide sample cars</b> asks first (&quot;Hide all 20 sample cars from the site?&quot;); press <b class="gd-ui">Hide them</b> to take every sample car off the site at once, or <b class="gd-ui">Keep them</b>. Nothing else stops it: not an enquiry, not an old request.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Show sample cars</b> puts the 20 back, with their photos and rates. Ones that were deleted are made again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the site each one is marked &quot;Example car&quot;. They never appear in search engines or the sitemap.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A request on a sample car is never a booking. When the person picks dates, the car page and the request form show a real car free for them (the same make and model first, else the same class and body at a similar price) with one tap to switch to it. If they keep the sample car, it becomes an enquiry (number EQ-1001 and up) and customer service gets the task Suggest a similar real car, naming the free real car.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Hide the sample cars once enough real cars are on the site. Delete all sample cars removes them for good.</div></aside></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-why-a-car-is-not-on-the-site-yet" data-gd-task><h2 class="gd-h2">Why a car is not on the site yet</h2><p class="gd-p"><b class="gd-ui">Cars</b> &gt; <b class="gd-ui">Vehicles</b>, the card Not on the site yet.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every real car that is not on the site is listed with its next step first: the rates, Publish now, the listing review.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The same car is a line on To do with <b class="gd-ui">Set rates and publish</b>. The car comes off both once it is on the site.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A car without photos is marked sample photos: once listed it shows a sample photo until its real photos are approved.</div></li></ol></div></section><section class="gd-task" id="partners-company-cars-and-rentals-added-by-hand-tolls-when-two-rentals-overlap" data-gd-task><h2 class="gd-h2">Tolls when two rentals overlap</h2><p class="gd-p">Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.</p></section>');
select app.guide_release_section('va', 'add-a-rental-by-hand', 'chapter', 'sales', 'Every function adds rentals that come in by phone, at the counter, from Turo, a partner, an insurer or someone you know. The rental is confirmed and on the calendar at once.

## Add a rental

Open **Bookings** > **Add a rental**. Your home address must be in your profile first: until it is, the page asks for it.

1. Choose the car, the dates and the places. The check shows any clash with another booking or with the cleaning time after a trip. You cannot book over a clash: ask an Admin.
2. The dates decide the case, shown under them. Car already out with the renter? Enter the pickup as when it left: the rental is recorded as on trip, and anything still missing (signature, licence check, coverage proof, deposit) becomes a task. A rental that has already ended is recorded by an Admin.
3. Find the renter by name, email or phone, or add a new one with their name, email, phone, date of birth and licence. Add any other drivers.
4. The calendar and the price are checked by themselves once the car and the dates are in. The price comes from the rate sheet. You may add the extras, how damage is covered and an allowed promo code.
5. Quick start: **Phone**, **Walk-in**, **Turo or another platform** or **Insurance replacement** sets the usual choices.
6. A car tagged Listing not finished can be rented too: it stays off the public site. If it has no rates yet, type the rental charge for the whole rental and the reason. An owner''s car not yet on the fleet insurance policy is added by an Admin only.
7. Every line of the price can be changed where it stands (customer service and sales, while Program settings allow it): the rental charge for the trip or a rate a day, the young driver fee, the Protection Plan, delivery, each add-on, the kilometres a day; add a fee from the list or a charge of its own. The (i) beside each line says what it is. The rate-sheet price stays on the booking; a price far under it is flagged for an Admin, never refused.
8. Any length: past 30 days the monthly rate applies for each 30 days, and the monthly periods are listed.
9. Choose how the rent is paid (e-Transfer or cash received, card on file, payment link, platform payout, insurer billed later; the ways open to you are set by an Admin; paid in parts: Add another payment) and then how the deposit is paid (card hold, cash or e-Transfer with its reference). Before you save sums it all up. Signed on paper already? Choose it: a task asks for the scan. An insurance replacement with dates not known yet: untick Blocks the car''s calendar and say why.
10. Under Who found this client, choose **I sourced this client** or **Entered for CarmaCars**.
11. Press **Add the rental**. The renter gets the confirmation email unless you tick **Do not email the renter**.
12. A rental you add is credited to you and shows in My sales as a rental you added. If you sourced it, its commission shows there too.

> Tip: The renter signs the rental agreement in their portal before pickup. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign. If they sign on paper at the counter, an Admin records it. A payment link keeps the booking waiting for payment.
', 'Add a rental by hand', 'Choose the car and dates, find the renter, price it, record how it is paid.',
  'Every function adds rentals that come in by phone, at the counter, from Turo, a partner, an insurer or someone you know. The rental is confirmed and on the calendar at once.

## Add a rental

Open **Bookings** > **Add a rental**. Your home address must be in your profile first: until it is, the page asks for it.

1. At pickup with the renter? Press **Start at pickup**: the renter''s name and phone, the car, the kilometres and the fuel, then **Hold the car and finish later**. The car is held for 2 hours and you get a task to finish it.
2. Nothing is required to save: the form is saved as a draft as you type (**Save draft** saves at once). Unfinished rentals, on Today and on this page, opens a draft where it was left, on any device. Tick Hold the car while I finish to keep the car off the calendar while you type.
3. Choose the car, the dates and the places. The check shows any clash with another booking or with the cleaning time after a trip. You cannot book over a clash: ask an Admin.
4. The dates decide the case, shown under them. Car already out with the renter? Enter the pickup as when it left: the rental is recorded as on trip, and anything still missing (signature, licence check, coverage proof, deposit) becomes a task. A rental that has already ended is recorded by an Admin.
5. Find the renter by name, email or phone, or add a new one with their name, email, phone, date of birth and licence. Add any other drivers.
6. The calendar and the price are checked by themselves once the car and the dates are in. The price comes from the rate sheet. You may add the extras, how damage is covered and an allowed promo code.
7. Quick start: **Phone**, **Walk-in**, **Turo or another platform** or **Insurance replacement** sets the usual choices.
8. A car tagged Listing not finished can be rented too: it stays off the public site. If it has no rates yet, type the rental charge for the whole rental and the reason. An owner''s car not yet on the fleet insurance policy is added by an Admin only.
9. Every line of the price can be changed where it stands (customer service and sales, while Program settings allow it): the rental charge for the trip or a rate a day, the young driver fee, the Protection Plan, delivery, each add-on, the kilometres a day; add a fee from the list or a charge of its own. The (i) beside each line says what it is. The rate-sheet price stays on the booking; a price far under it is flagged for an Admin, never refused.
10. Any length: past 30 days the monthly rate applies for each 30 days, and the monthly periods are listed. Each later period gets its own agreement, sent to the renter to sign a few days before it starts (Monthly periods on the booking; Send the agreement for the next period now if needed).
11. Choose how the rent is paid (e-Transfer or cash received, card on file, payment link, platform payout, insurer billed later; the ways open to you are set by an Admin; paid in parts: Add another payment) and then how the deposit is paid (card hold, cash or e-Transfer with its reference). Before you save sums it all up. Signed on paper already? Choose it: a task asks for the scan. An insurance replacement with dates not known yet: untick Blocks the car''s calendar and say why.
12. Under Who found this client, choose **I sourced this client** or **Entered for CarmaCars**.
13. Press **Add the rental**. The renter gets the confirmation email unless you tick **Do not email the renter**.
14. A rental you add is credited to you and shows in My sales as a rental you added. If you sourced it, its commission shows there too.

> Tip: The renter signs the rental agreement in their portal before pickup. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign. If they sign on paper at the counter, an Admin records it. A payment link keeps the booking waiting for payment.
',
  '<p class="gd-p">Every function adds rentals that come in by phone, at the counter, from Turo, a partner, an insurer or someone you know. The rental is confirmed and on the calendar at once.</p><section class="gd-task" id="add-a-rental-by-hand-add-a-rental" data-gd-task><h2 class="gd-h2">Add a rental</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Add a rental</b>. Your home address must be in your profile first: until it is, the page asks for it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">At pickup with the renter? Press <b class="gd-ui">Start at pickup</b>: the renter&#39;s name and phone, the car, the kilometres and the fuel, then <b class="gd-ui">Hold the car and finish later</b>. The car is held for 2 hours and you get a task to finish it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Nothing is required to save: the form is saved as a draft as you type (<b class="gd-ui">Save draft</b> saves at once). Unfinished rentals, on Today and on this page, opens a draft where it was left, on any device. Tick Hold the car while I finish to keep the car off the calendar while you type.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Choose the car, the dates and the places. The check shows any clash with another booking or with the cleaning time after a trip. You cannot book over a clash: ask an Admin.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The dates decide the case, shown under them. Car already out with the renter? Enter the pickup as when it left: the rental is recorded as on trip, and anything still missing (signature, licence check, coverage proof, deposit) becomes a task. A rental that has already ended is recorded by an Admin.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Find the renter by name, email or phone, or add a new one with their name, email, phone, date of birth and licence. Add any other drivers.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">The calendar and the price are checked by themselves once the car and the dates are in. The price comes from the rate sheet. You may add the extras, how damage is covered and an allowed promo code.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Quick start: <b class="gd-ui">Phone</b>, <b class="gd-ui">Walk-in</b>, <b class="gd-ui">Turo or another platform</b> or <b class="gd-ui">Insurance replacement</b> sets the usual choices.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">A car tagged Listing not finished can be rented too: it stays off the public site. If it has no rates yet, type the rental charge for the whole rental and the reason. An owner&#39;s car not yet on the fleet insurance policy is added by an Admin only.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Every line of the price can be changed where it stands (customer service and sales, while Program settings allow it): the rental charge for the trip or a rate a day, the young driver fee, the Protection Plan, delivery, each add-on, the kilometres a day; add a fee from the list or a charge of its own. The (i) beside each line says what it is. The rate-sheet price stays on the booking; a price far under it is flagged for an Admin, never refused.</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Any length: past 30 days the monthly rate applies for each 30 days, and the monthly periods are listed. Each later period gets its own agreement, sent to the renter to sign a few days before it starts (Monthly periods on the booking; Send the agreement for the next period now if needed).</div></li><li><span class="gd-n" aria-hidden="true">11</span><div class="gd-t">Choose how the rent is paid (e-Transfer or cash received, card on file, payment link, platform payout, insurer billed later; the ways open to you are set by an Admin; paid in parts: Add another payment) and then how the deposit is paid (card hold, cash or e-Transfer with its reference). Before you save sums it all up. Signed on paper already? Choose it: a task asks for the scan. An insurance replacement with dates not known yet: untick Blocks the car&#39;s calendar and say why.</div></li><li><span class="gd-n" aria-hidden="true">12</span><div class="gd-t">Under Who found this client, choose <b class="gd-ui">I sourced this client</b> or <b class="gd-ui">Entered for CarmaCars</b>.</div></li><li><span class="gd-n" aria-hidden="true">13</span><div class="gd-t">Press <b class="gd-ui">Add the rental</b>. The renter gets the confirmation email unless you tick <b class="gd-ui">Do not email the renter</b>.</div></li><li><span class="gd-n" aria-hidden="true">14</span><div class="gd-t">A rental you add is credited to you and shows in My sales as a rental you added. If you sourced it, its commission shows there too.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The renter signs the rental agreement in their portal before pickup. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign. If they sign on paper at the counter, an Admin records it. A payment link keeps the booking waiting for payment.</div></aside></section>');
-- GUIDES 0145 END

-- ================================================================ privileges
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['may_draft', 'draft_missing', 'draft_save', 'draft_close', 'drafts_list', 'draft_get',
                     'manual_rental_create', 'manual_rental_create_pre0145', 'door', 'door_pre0145', 'booking_periods_sync', 'booking_periods_trg',
                     'booking_periods_list', 'booking_period_send_now', 'server_jobs_due', 'server_jobs_due_pre0145'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = any (array['server_periods_due', 'server_period_begin', 'server_period_done', 'server_agreement_facts', 'server_agreement_facts_pre0145'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
