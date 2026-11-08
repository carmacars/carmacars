-- 0931: field shifts given up and swapped, the pay details step, and Sales for field staff (Release 35, part X;
-- docs/changes/2026-11-08-r35-field-portal.md). No applied migration is edited.
--   1. Giving up a shift needs a reason. The shift is offered at once (alert and text) to every field person who passed the
--      academy and is free then; the first to claim takes it (the slot's capacity decides). Unclaimed field_offer_alert_hours
--      before the start, Fleet and Admin are alerted with a To do. A give-up under field_late_cancel_hours is flagged on the
--      person's record (the board counts the last 90 days). Two people swap shifts: one asks, the other accepts.
--   2. My shifts: the upcoming shifts with the work planned so far, the past ones with what was done (jobs, photos, money
--      spent, hours).
--   3. Pay details (staff_pay_identity): full legal name, email, phone, the SIN (encrypted by the website as the payout
--      account numbers are, 0022/0730; only the last 3 digits are kept in clear and shown as ***-***-123) and a void cheque
--      (a private file). Only Finance and Admin read the SIN or open the cheque, each time logged (audit_log and
--      data_access_log). Every field person without them has a To do; Finance has the list of who is missing them.
--   4. "I want to do sales too": a field person opts in, the Sales academy path is added to theirs (it never holds their field
--      work), and the Sales function is added the moment that path is passed.
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

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description) values
  ('field_shift_unclaimed', 'fleet', 'A given-up field shift has nobody', 'high', 'none', null, 'A field person gave up a shift and nobody claimed it yet. Put someone on it on the field jobs board.'),
  ('field_pay_details', 'fleet', 'Enter your pay details', 'normal', 'none', null, 'My pay > Pay details: your full legal name, email, phone, SIN and a void cheque. Needed before you are paid.')
on conflict (task_type) do nothing;

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  ('field_shift_offer', 'A field shift is free: first to claim takes it', 'Field work', '{assigned}', 'urgent', 'alerts', true, false, 'A field person gave up a shift; every eligible person free then is told (0931).', 155),
  ('field_shift_unclaimed', 'A given-up field shift has nobody', 'Field work', '{admin,on_duty:fleet}', 'urgent', 'alerts', true, false, 'Nobody claimed a given-up shift by field_offer_alert_hours before it starts (0931).', 156),
  ('field_shift_swap', 'A shift swap asked of you', 'Field work', '{assigned}', 'normal', 'alerts', true, false, 'Another field person asked to swap shifts with you (0931).', 157)
on conflict (rule) do nothing;

-- ================================================================ 1. giving up, offering, claiming, swapping
alter table field_shift_plans
  add column cancel_reason text check (length(cancel_reason) <= 300),
  add column late_cancel boolean not null default false;
comment on column field_shift_plans.late_cancel is 'Given up less than field_late_cancel_hours before the start (0931): flagged on the person''s record.';

create table field_shift_offers (
  id           uuid primary key default gen_random_uuid(),
  kind         text not null check (kind in ('giveaway', 'swap')),
  slot_id      uuid not null references field_shift_slots (id),
  plan_id      uuid not null references field_shift_plans (id),
  from_staff   uuid not null references users (id),
  target_plan  uuid references field_shift_plans (id),
  reason       text check (length(reason) <= 300),
  late         boolean not null default false,
  starts_at    timestamptz not null,
  ends_at      timestamptz not null,
  status       text not null default 'open' check (status in ('open', 'claimed', 'declined', 'expired', 'withdrawn')),
  claimed_by   uuid references users (id),
  claimed_at   timestamptz,
  offered_to   integer not null default 0,
  alerted_at   timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check ((kind = 'swap') = (target_plan is not null))
);
create index field_shift_offers_open on field_shift_offers (starts_at) where status = 'open';
create trigger field_shift_offers_updated before update on field_shift_offers for each row execute function app.set_updated_at();
alter table field_shift_offers enable row level security;
create policy admin_all on field_shift_offers for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on field_shift_offers from public, anon, authenticated;
grant select on field_shift_offers to authenticated;
grant all on field_shift_offers to service_role;
create trigger audit_field_shift_offers after insert or update or delete on field_shift_offers for each row execute function app.audit_row();
comment on table field_shift_offers is 'A field shift given up (giveaway: offered to everyone eligible, first to claim takes it) or a swap asked of one person (0931).';

-- the people a free shift goes to: field staff past the academy, active, not the giver, free at that time
create function app.fx_free_people(p_from uuid, p_start timestamptz, p_end timestamptz) returns setof uuid
language sql stable security definer set search_path = public, app as $$
  select u.id from users u
   where app.is_field_person(u.id) and u.id <> p_from and not u.is_test and not app.academy_locked(u.id)
     and not exists (select 1 from field_shift_plans x where x.staff_id = u.id and x.cancelled_at is null and x.starts_at < p_end and p_start < x.ends_at)
$$;

create function app.fx_shift_words(p_start timestamptz, p_end timestamptz) returns text
language sql stable as $$
  select to_char(p_start at time zone 'America/Toronto', 'Dy Mon DD, HH12:MI AM') || ' to ' || to_char(p_end at time zone 'America/Toronto', 'HH12:MI AM')
$$;

-- p: id (the plan), reason
create function app.fx_shift_cancel(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x field_shift_plans;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_late boolean;
  v_offer uuid;
  v_n integer := 0;
  u record;
  v_name text;
  v_words text;
begin
  select * into x from field_shift_plans where id = nullif(p ->> 'id', '')::uuid and cancelled_at is null for update;
  if x.id is null then raise exception 'That shift is not there any more' using errcode = 'P0002'; end if;
  if x.staff_id <> p_user then raise exception 'That shift is not yours' using errcode = '42501'; end if;
  if x.starts_at <= now() then raise exception 'This shift has started: ask Fleet' using errcode = '23514'; end if;
  if length(coalesce(v_reason, '')) < 3 then raise exception 'Say why you cannot work this shift' using errcode = '22023'; end if;
  v_late := x.starts_at - now() < make_interval(hours => (app.settings()).field_late_cancel_hours);
  update field_shift_plans set cancelled_at = now(), cancelled_by = p_user, cancel_reason = left(v_reason, 300), late_cancel = v_late where id = x.id;
  update field_shift_offers set status = 'withdrawn' where status = 'open' and kind = 'swap' and (plan_id = x.id or target_plan = x.id);
  insert into field_shift_offers (kind, slot_id, plan_id, from_staff, reason, late, starts_at, ends_at)
  values ('giveaway', x.slot_id, x.id, p_user, left(v_reason, 300), v_late, x.starts_at, x.ends_at) returning id into v_offer;
  select full_name into v_name from users where id = p_user;
  v_words := app.fx_shift_words(x.starts_at, x.ends_at);
  for u in select f.id, us.phone from app.fx_free_people(p_user, x.starts_at, x.ends_at) f(id) join users us on us.id = f.id loop
    v_n := v_n + 1;
    perform app.staff_alert('field_shift_offer', 'field_shift_offer', v_offer, 'to:' || u.id, 'A shift is free: ' || v_words,
      'First to claim takes it. Open My shifts and press Claim.', jsonb_build_object('assigned_to', u.id, 'path_staff', '/staff/field/shifts'));
    if app.phone_e164(u.phone) is not null then
      perform app.phone_outbox_put(u.phone, format('CarmaCars: a field shift is free, %s. First to claim takes it: My shifts in your staff portal.', v_words),
        'staff', null, null, null, null, 'shift_offer:' || v_offer || ':' || u.id, now(), 'queued', p_user);
    end if;
  end loop;
  update field_shift_offers set offered_to = v_n where id = v_offer;
  return jsonb_build_object('id', x.id, 'offer', v_offer, 'offered_to', v_n, 'late', v_late);
end $$;

-- the first to claim takes it: the slot's capacity, the academy and the overlap rules of 0880 decide
create function app.fx_offer_claim(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o field_shift_offers;
  v jsonb;
begin
  select * into o from field_shift_offers where id = nullif(p ->> 'id', '')::uuid for update;
  if o.id is null or o.kind <> 'giveaway' then raise exception 'That shift is not offered' using errcode = 'P0002'; end if;
  if o.status <> 'open' then raise exception 'Someone already claimed this shift' using errcode = '23514'; end if;
  if o.from_staff = p_user then raise exception 'You gave this shift up' using errcode = '23514'; end if;
  v := app.field_shift_book(p_user, o.slot_id, p_user);
  return v || jsonb_build_object('offer', o.id);
end $$;

-- a taken slot closes the oldest open giveaway on it (claimed from the offer, or taken from the open shifts)
create function app.fx_plan_after_insert() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  update field_shift_offers set status = 'claimed', claimed_by = new.staff_id, claimed_at = now()
   where id = (select o.id from field_shift_offers o where o.slot_id = new.slot_id and o.kind = 'giveaway' and o.status = 'open' and o.from_staff <> new.staff_id
                order by o.created_at limit 1);
  return null;
end $$;
create trigger field_shift_plans_offer after insert on field_shift_plans for each row execute function app.fx_plan_after_insert();

-- p: mine (my plan), theirs (their plan)
create function app.fx_swap_ask(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a field_shift_plans;
  b field_shift_plans;
  v_id uuid;
begin
  select * into a from field_shift_plans where id = nullif(p ->> 'mine', '')::uuid and cancelled_at is null;
  select * into b from field_shift_plans where id = nullif(p ->> 'theirs', '')::uuid and cancelled_at is null;
  if a.id is null or a.staff_id <> p_user then raise exception 'Choose one of your shifts' using errcode = '42501'; end if;
  if b.id is null or b.staff_id = p_user then raise exception 'Choose the other person''s shift' using errcode = '22023'; end if;
  if a.starts_at <= now() or b.starts_at <= now() then raise exception 'Only shifts that have not started are swapped' using errcode = '23514'; end if;
  if app.academy_locked(b.staff_id) then raise exception 'That person cannot take shifts yet' using errcode = '23514'; end if;
  if exists (select 1 from field_shift_offers o where o.kind = 'swap' and o.status = 'open' and o.plan_id = a.id and o.target_plan = b.id) then
    raise exception 'You already asked for this swap' using errcode = '23505';
  end if;
  insert into field_shift_offers (kind, slot_id, plan_id, from_staff, target_plan, reason, starts_at, ends_at)
  values ('swap', a.slot_id, a.id, p_user, b.id, nullif(left(btrim(coalesce(p ->> 'note', '')), 300), ''), a.starts_at, a.ends_at) returning id into v_id;
  perform app.staff_alert('field_shift_swap', 'field_shift_offer', v_id, 'ask', format('%s asks to swap shifts', (select full_name from users where id = p_user)),
    format('Their %s for your %s. Accept or decline on My shifts.', app.fx_shift_words(a.starts_at, a.ends_at), app.fx_shift_words(b.starts_at, b.ends_at)),
    jsonb_build_object('assigned_to', b.staff_id, 'path_staff', '/staff/field/shifts'));
  return jsonb_build_object('id', v_id);
end $$;

-- p: id, accept
create function app.fx_swap_answer(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o field_shift_offers;
  a field_shift_plans;
  b field_shift_plans;
begin
  select * into o from field_shift_offers where id = nullif(p ->> 'id', '')::uuid and kind = 'swap' for update;
  if o.id is null or o.status <> 'open' then raise exception 'That swap is not open' using errcode = 'P0002'; end if;
  select * into a from field_shift_plans where id = o.plan_id for update;
  select * into b from field_shift_plans where id = o.target_plan for update;
  if b.staff_id <> p_user and not (o.from_staff = p_user and not coalesce((p ->> 'accept')::boolean, false)) then raise exception 'That swap is not asked of you' using errcode = '42501'; end if;
  if not coalesce((p ->> 'accept')::boolean, false) then
    update field_shift_offers set status = case when o.from_staff = p_user then 'withdrawn' else 'declined' end where id = o.id;
    return jsonb_build_object('id', o.id, 'status', 'declined');
  end if;
  if a.cancelled_at is not null or b.cancelled_at is not null or a.starts_at <= now() or b.starts_at <= now() then
    update field_shift_offers set status = 'expired' where id = o.id;
    raise exception 'One of the shifts has changed or started: the swap is off' using errcode = '23514';
  end if;
  update field_shift_plans set cancelled_at = now(), cancelled_by = p_user, cancel_reason = 'Swapped' where id in (a.id, b.id);
  perform app.field_shift_book(a.staff_id, b.slot_id, p_user);
  perform app.field_shift_book(b.staff_id, a.slot_id, p_user);
  update field_shift_offers set status = 'claimed', claimed_by = p_user, claimed_at = now() where id = o.id;
  return jsonb_build_object('id', o.id, 'status', 'swapped');
end $$;

-- every 15 minutes: the offers nobody claimed close to the start alert Fleet and Admin; past ones expire
create function app.job_field_shift_offers(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  o field_shift_offers;
  n integer := 0;
begin
  update field_shift_offers set status = 'expired' where status = 'open' and starts_at <= p_now;
  for o in select * from field_shift_offers x where x.status = 'open' and x.kind = 'giveaway' and x.alerted_at is null
             and x.starts_at - p_now <= make_interval(hours => (app.settings()).field_offer_alert_hours) loop
    perform app.raise_task(p_type => 'field_shift_unclaimed', p_title => 'Nobody claimed the field shift of ' || app.fx_shift_words(o.starts_at, o.ends_at),
      p_detail => format('%s gave it up: %s', (select full_name from users where id = o.from_staff), coalesce(o.reason, '')),
      p_related_table => 'field_shift_offers', p_related_id => o.id, p_queue => 'fleet', p_dedupe => 'field_shift_unclaimed:' || o.id, p_due_at => o.starts_at, p_priority => 'high');
    perform app.staff_alert('field_shift_unclaimed', 'field_shift_offer', o.id, 'unclaimed', 'Nobody claimed the shift of ' || app.fx_shift_words(o.starts_at, o.ends_at),
      'Put someone on it on the field jobs board.', jsonb_build_object('path_admin', '/admin/field-jobs', 'path_staff', '/staff/fleet'));
    update field_shift_offers set alerted_at = p_now where id = o.id;
    n := n + 1;
  end loop;
  return format('%s unclaimed shift(s) alerted', n);
end $$;
do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-field-shift-offers', '*/15 * * * *', 'select app.job_field_shift_offers()');
  end if;
end $$;

-- the board: each person's late give-ups of the last 90 days
alter function app.field_staff_board() rename to field_staff_board_pre0931;
create function app.field_staff_board() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(s || jsonb_build_object('late_cancels', (select count(*) from field_shift_plans x where x.staff_id = (s ->> 'id')::uuid and x.late_cancel
                                                                        and x.cancelled_at > now() - interval '90 days'))), '[]'::jsonb)
    from jsonb_array_elements(app.field_staff_board_pre0931()) s
$$;
select pg_temp.copy_grants('app.field_staff_board()'::regprocedure, 'app.field_staff_board_pre0931()'::regprocedure);

-- ================================================================ 2. My shifts
alter function app.field_my_shifts(uuid) rename to field_my_shifts_pre0931;
create function app.field_my_shifts(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.field_my_shifts_pre0931(p_user) || jsonb_build_object(
    'planned', coalesce((select jsonb_object_agg(x.id, jsonb_build_object('cards', (select coalesce(jsonb_agg(jsonb_build_object('type', c ->> 'type', 'leg', c ->> 'leg', 'kind', c ->> 'kind',
                                      'at', c ->> 'at', 'vehicle', c #>> '{vehicle,name}', 'booking', c #>> '{booking,number}')), '[]'::jsonb)
                                    from jsonb_array_elements(app.fx_today(p_user, app.local_date(x.starts_at)) -> 'cards') c where (c ->> 'must')::boolean)))
                          from (select * from field_shift_plans y where y.staff_id = p_user and y.cancelled_at is null and y.ends_at > now() order by y.starts_at limit 14) x), '{}'::jsonb),
    'offers', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'slot_id', o.slot_id, 'starts_at', o.starts_at, 'ends_at', o.ends_at, 'from', (select split_part(u.full_name, ' ', 1) from users u where u.id = o.from_staff))
                          order by o.starts_at)
                         from field_shift_offers o where o.kind = 'giveaway' and o.status = 'open' and o.from_staff <> p_user and o.starts_at > now()
                          and not app.academy_locked(p_user)
                          and not exists (select 1 from field_shift_plans x where x.staff_id = p_user and x.cancelled_at is null and x.starts_at < o.ends_at and o.starts_at < x.ends_at)), '[]'::jsonb),
    'swaps', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'incoming', b.staff_id = p_user, 'theirs', jsonb_build_object('starts_at', a.starts_at, 'ends_at', a.ends_at),
                          'mine', jsonb_build_object('starts_at', b.starts_at, 'ends_at', b.ends_at),
                          'who', (select split_part(u.full_name, ' ', 1) from users u where u.id = case when b.staff_id = p_user then o.from_staff else b.staff_id end)) order by o.created_at)
                         from field_shift_offers o join field_shift_plans a on a.id = o.plan_id join field_shift_plans b on b.id = o.target_plan
                        where o.kind = 'swap' and o.status = 'open' and (b.staff_id = p_user or o.from_staff = p_user)), '[]'::jsonb),
    'others', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'starts_at', x.starts_at, 'ends_at', x.ends_at, 'who', split_part(u.full_name, ' ', 1)) order by x.starts_at)
                         from field_shift_plans x join users u on u.id = x.staff_id
                        where x.staff_id <> p_user and x.cancelled_at is null and x.starts_at > now() and x.starts_at < now() + interval '21 days'), '[]'::jsonb),
    'late_cancels', (select count(*) from field_shift_plans x where x.staff_id = p_user and x.late_cancel and x.cancelled_at > now() - interval '90 days'),
    'past', coalesce((select jsonb_agg(jsonb_build_object('day', d.day,
               'minutes', (select coalesce(sum(round(extract(epoch from (f.ended_at - f.started_at)) / 60)), 0)::integer from field_shifts f
                            where f.staff_id = p_user and f.voided_at is null and f.ended_at is not null and app.local_date(f.started_at) = d.day),
               'jobs', (select coalesce(jsonb_agg(jsonb_build_object('kind', j.kind, 'vehicle', app.vehicle_name(j.vehicle_id), 'booking', (select b.booking_number from bookings b where b.id = j.booking_id))
                                          order by j.completed_at), '[]'::jsonb)
                          from field_jobs j where j.assigned_to = p_user and j.status = 'done' and app.local_date(j.completed_at) = d.day),
               'photos', (select count(*) from vehicle_clean_checks c where c.checked_by = p_user and app.local_date(c.checked_at) = d.day)
                         + (select count(*) from condition_report_photos ph join condition_reports r on r.id = ph.condition_report_id
                             where r.performed_by = p_user and app.local_date(r.created_at) = d.day),
               'spent_cents', (select coalesce(sum(s.amount_cents + s.hst_cents), 0) from field_spends s where s.staff_id = p_user and s.spent_on = d.day and s.status <> 'refused'),
               'spends', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'description', s.description, 'amount_cents', s.amount_cents + s.hst_cents, 'status', s.status,
                                            'receipt', s.receipt_document_id is not null)), '[]'::jsonb) from field_spends s where s.staff_id = p_user and s.spent_on = d.day))
               order by d.day desc)
          from (select distinct app.local_date(f.started_at) as day from field_shifts f where f.staff_id = p_user and f.voided_at is null and f.started_at > now() - interval '30 days' and f.started_at < app.local_midnight(app.today())
                union select distinct app.local_date(x.starts_at) from field_shift_plans x where x.staff_id = p_user and x.cancelled_at is null and x.ends_at < now() and x.starts_at > now() - interval '30 days') d), '[]'::jsonb))
$$;
select pg_temp.copy_grants('app.field_my_shifts(uuid)'::regprocedure, 'app.field_my_shifts_pre0931(uuid)'::regprocedure);

-- ================================================================ 3. pay details
create table staff_pay_identity (
  user_id        uuid primary key references users (id) on delete cascade,
  legal_name     text check (length(btrim(legal_name)) between 2 and 160),
  email          text check (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  phone          text check (length(phone) between 7 and 30),
  sin_enc        text check (sin_enc ~ '^v[0-9]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$'),
  sin_last3      text check (sin_last3 ~ '^[0-9]{3}$'),
  key_version    integer,
  cheque_path    text check (cheque_path ~ '^staff-pay/[0-9a-f-]{36}/[0-9a-f-]{36}\.(jpg|png|pdf)$'),
  cheque_mime    text,
  cheque_sha256  text,
  completed_at   timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  updated_by     uuid references users (id),
  check ((sin_enc is null) = (sin_last3 is null))
);
create trigger staff_pay_identity_updated before update on staff_pay_identity for each row execute function app.set_updated_at();
alter table staff_pay_identity enable row level security;
-- the admin policy has no grant behind it (as staff_payout_accounts, 0730): no browser reads the table
create policy admin_all on staff_pay_identity for select to authenticated using (app.is_admin());
revoke all on staff_pay_identity from public, anon, authenticated;
grant all on staff_pay_identity to service_role;
-- the values are never in the audit log (who changed it and when only), as the payout accounts (0730)
create trigger audit_staff_pay_identity after insert or update or delete on staff_pay_identity for each row execute function app.audit_row('redact');
comment on table staff_pay_identity is 'A staff member''s pay details for payroll (0931): full legal name, email, phone, SIN (sin_enc: encrypted by the website, v1.<iv>.<ciphertext>; sin_last3 in clear) and a void cheque in the private documents bucket. No browser reads it: only the functions below, and only Finance and Admin see the SIN or the cheque, each time logged.';

create function app.pay_identity_missing(x staff_pay_identity) returns text[]
language sql immutable as $$
  select array_remove(array[case when x.legal_name is null then 'full legal name' end, case when x.email is null then 'email' end,
    case when x.phone is null then 'phone' end, case when x.sin_enc is null then 'SIN' end, case when x.cheque_path is null then 'void cheque' end], null)
$$;

create function app.pay_identity_view(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare x staff_pay_identity;
begin
  select * into x from staff_pay_identity where user_id = p_user;
  return jsonb_build_object('legal_name', x.legal_name, 'email', coalesce(x.email, (select u.email from users u where u.id = p_user)),
    'phone', coalesce(x.phone, (select u.phone from users u where u.id = p_user)), 'sin', case when x.sin_last3 is not null then '***-***-' || x.sin_last3 end,
    'cheque', x.cheque_path is not null, 'complete', x.completed_at is not null,
    'missing', to_jsonb(case when x.user_id is null then array['full legal name', 'SIN', 'void cheque'] else app.pay_identity_missing(x) end));
end $$;

-- p: legal_name, email, phone, sin_enc, sin_last3, key_version (the website encrypted the SIN), cheque {storage_path, mime_type, sha256}
create function app.pay_identity_save(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x staff_pay_identity;
  v_name text := nullif(btrim(coalesce(p ->> 'legal_name', '')), '');
  v_email text := nullif(lower(btrim(coalesce(p ->> 'email', ''))), '');
  v_phone text := nullif(btrim(coalesce(p ->> 'phone', '')), '');
begin
  if not exists (select 1 from user_roles r where r.user_id = p_user and r.role in ('va', 'field')) then raise exception 'Pay details are for staff' using errcode = '42501'; end if;
  if v_name is not null and length(v_name) < 2 then raise exception 'Enter your full legal name' using errcode = '22023'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Check the email address' using errcode = '22023'; end if;
  if v_phone is not null and length(regexp_replace(v_phone, '[^0-9]', '', 'g')) < 10 then raise exception 'Check the phone number' using errcode = '22023'; end if;
  if nullif(p ->> 'sin_enc', '') is not null and (coalesce(p ->> 'sin_last3', '') !~ '^[0-9]{3}$' or (p ->> 'sin_enc') !~ '^v[0-9]+\.') then
    raise exception 'The SIN could not be saved: enter it again' using errcode = '22023';
  end if;
  if nullif(p -> 'cheque' ->> 'storage_path', '') is not null and (p -> 'cheque' ->> 'storage_path') !~ ('^staff-pay/' || p_user || '/[0-9a-f-]{36}\.(jpg|png|pdf)$') then
    raise exception 'The void cheque upload is not yours' using errcode = '22023';
  end if;
  insert into staff_pay_identity (user_id, updated_by) values (p_user, p_user) on conflict (user_id) do nothing;
  update staff_pay_identity set
    legal_name = coalesce(v_name, legal_name), email = coalesce(v_email, email), phone = coalesce(v_phone, phone),
    sin_enc = coalesce(nullif(p ->> 'sin_enc', ''), sin_enc), sin_last3 = case when nullif(p ->> 'sin_enc', '') is not null then p ->> 'sin_last3' else sin_last3 end,
    key_version = case when nullif(p ->> 'sin_enc', '') is not null then nullif(p ->> 'key_version', '')::integer else key_version end,
    cheque_path = coalesce(nullif(p -> 'cheque' ->> 'storage_path', ''), cheque_path),
    cheque_mime = case when nullif(p -> 'cheque' ->> 'storage_path', '') is not null then p -> 'cheque' ->> 'mime_type' else cheque_mime end,
    cheque_sha256 = case when nullif(p -> 'cheque' ->> 'storage_path', '') is not null then p -> 'cheque' ->> 'sha256' else cheque_sha256 end,
    updated_by = p_user
   where user_id = p_user returning * into x;
  if cardinality(app.pay_identity_missing(x)) = 0 and x.completed_at is null then
    update staff_pay_identity set completed_at = now() where user_id = p_user;
    update tasks set status = 'done', completed_at = now(), completed_by = p_user, completion_note = 'Pay details entered'
     where dedupe_key = 'field_pay_details:' || p_user and status in ('open', 'in_progress', 'waiting');
  end if;
  return app.pay_identity_view(p_user);
end $$;

-- Finance and Admin: every field person and whether their pay details are in
create function app.pay_identity_list(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.user_runs_finance(p_by) then raise exception 'Only Finance or an Admin sees the pay details' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('user_id', u.id, 'name', u.full_name, 'legal_name', x.legal_name, 'email', x.email, 'phone', x.phone,
           'sin', case when x.sin_last3 is not null then '***-***-' || x.sin_last3 end, 'cheque', x.cheque_path is not null, 'complete', x.completed_at is not null,
           'missing', to_jsonb(case when x.user_id is null then array['full legal name', 'email', 'phone', 'SIN', 'void cheque'] else app.pay_identity_missing(x) end))
           order by (x.completed_at is not null), u.full_name)
    from users u left join staff_pay_identity x on x.user_id = u.id where app.is_field_person(u.id) and not u.is_test), '[]'::jsonb);
end $$;

-- Finance and Admin open the SIN or the cheque: the encrypted value or the file's path goes to the website, which decrypts
-- or signs it; each view is logged with the reason
create function app.pay_identity_reveal(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x staff_pay_identity;
  v_what text := coalesce(p ->> 'what', 'sin');
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
begin
  if not app.user_runs_finance(p_by) then raise exception 'Only Finance or an Admin sees the pay details' using errcode = '42501'; end if;
  if v_what not in ('sin', 'cheque') then raise exception 'Choose the SIN or the cheque' using errcode = '22023'; end if;
  if length(coalesce(v_reason, '')) < 3 then raise exception 'Say why you need it (for example: payroll)' using errcode = '22023'; end if;
  select * into x from staff_pay_identity where user_id = nullif(p ->> 'user', '')::uuid;
  if x.user_id is null or (v_what = 'sin' and x.sin_enc is null) or (v_what = 'cheque' and x.cheque_path is null) then raise exception 'Not entered yet' using errcode = 'P0002'; end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'staff_' || v_what || '_view', 'staff_pay_identity', x.user_id::text, jsonb_build_object('reason', left(v_reason, 200)));
  insert into data_access_log (user_id, action, query, reason, results) values (p_by, 'open', 'staff pay ' || v_what || ': ' || x.user_id, left(v_reason, 200), 1);
  return case v_what when 'sin' then jsonb_build_object('sin_enc', x.sin_enc, 'key_version', x.key_version)
                     else jsonb_build_object('path', x.cheque_path, 'mime', x.cheque_mime) end;
end $$;

-- a To do for every field person whose pay details are not in (the ones there now, and each new one)
create function app.fx_pay_details_todo(p_user uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare v_t uuid;
begin
  if not app.is_field_person(p_user) or exists (select 1 from users u where u.id = p_user and u.is_test)
     or exists (select 1 from staff_pay_identity x where x.user_id = p_user and x.completed_at is not null) then return; end if;
  -- the person's name in the title: the queue hygiene merges open tasks of the same type and title (0325)
  v_t := app.raise_task(p_type => 'field_pay_details', p_title => format('Enter your pay details (%s): legal name, SIN and a void cheque', (select coalesce(u.full_name, u.email) from users u where u.id = p_user)),
    p_detail => 'My pay > Pay details. Needed before you are paid. Only Finance and Admin can see your SIN, and only its last 3 digits are shown.',
    p_related_table => 'users', p_related_id => p_user, p_queue => 'fleet', p_dedupe => 'field_pay_details:' || p_user);
  if v_t is not null then update tasks set assigned_to = p_user where id = v_t; end if;
end $$;
create function app.fx_role_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.role = 'field' then perform app.fx_pay_details_todo(new.user_id); end if;
  return null;
end $$;
create trigger user_roles_field_pay_details after insert on user_roles for each row execute function app.fx_role_after();
select app.fx_pay_details_todo(u.id) from users u where app.is_field_person(u.id) and not u.is_test;

-- ================================================================ 4. Sales for field staff
alter table staff_profiles add column sales_opt_in_at timestamptz;
comment on column staff_profiles.sales_opt_in_at is 'A field person asked to do sales too (0931): the Sales academy path is on their academy (without holding their field work), and the Sales function is added once it is passed.';

create function app.fx_sales_path(p_user uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case when sp.sales_work_mode = 'remote' then 'sales_remote' else 'sales_in_person' end from staff_profiles sp where sp.user_id = p_user
$$;

create function app.fx_sales_path_done(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select not exists (select 1 from academy_path_sections ps where ps.path_code = app.fx_sales_path(p_user) and not app.academy_passed(p_user, ps.section_id))
$$;

-- the Sales function, once the path is passed
create function app.fx_sales_grant(p_user uuid) returns boolean
language plpgsql security definer set search_path = public, app as $$
begin
  if not exists (select 1 from staff_profiles sp where sp.user_id = p_user and sp.sales_opt_in_at is not null and sp.is_active and not 'sales' = any (sp.functions)) then return false; end if;
  if not app.fx_sales_path_done(p_user) then return false; end if;
  update staff_profiles set functions = array_append(functions, 'sales'), sales_work_mode = coalesce(sales_work_mode, 'in_person') where user_id = p_user;
  return true;
end $$;

create function app.fx_attempt_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.passed then perform app.fx_sales_grant(new.user_id); end if;
  return null;
end $$;
create trigger academy_attempts_sales_grant after insert on academy_attempts for each row execute function app.fx_attempt_after();

-- p: on (true: "I want to do sales too"; false: stop)
create function app.fx_sales_optin(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_on boolean := coalesce((p ->> 'on')::boolean, true);
begin
  if not app.is_field_person(p_user) then raise exception 'Only field staff opt in to sales here' using errcode = '42501'; end if;
  if v_on then
    update staff_profiles set sales_opt_in_at = coalesce(sales_opt_in_at, now()), sales_work_mode = coalesce(sales_work_mode, 'in_person') where user_id = p_user;
    insert into academy_enrollments (user_id, path_code, gate, lock_from, source, enrolled_by)
    values (p_user, app.fx_sales_path(p_user), true, now(), 'existing', p_user) on conflict (user_id, path_code) do nothing;
    perform app.fx_sales_grant(p_user);
  else
    update staff_profiles set functions = case when sales_opt_in_at is not null then array_remove(functions, 'sales') else functions end, sales_opt_in_at = null where user_id = p_user;
    delete from academy_enrollments where user_id = p_user and path_code in ('sales_in_person', 'sales_remote') and source = 'existing'
       and not exists (select 1 from staff_profiles sp where sp.user_id = p_user and 'sales' = any (sp.functions));
  end if;
  return app.fx_sales_state(p_user);
end $$;

create function app.fx_sales_state(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('opted_in', sp.sales_opt_in_at is not null, 'since', sp.sales_opt_in_at, 'sales', 'sales' = any (sp.functions),
    'path', app.fx_sales_path(p_user), 'ready', 'sales' = any (sp.functions),
    'progress', (select app.academy_path_progress(p_user, app.fx_sales_path(p_user))))
    from staff_profiles sp where sp.user_id = p_user
$$;

-- the opted-in person's academy includes the Sales path; it never holds their field work
alter function app.academy_paths_of(uuid) rename to academy_paths_of_pre0931;
create function app.academy_paths_of(p_user uuid) returns text[]
language sql stable security definer set search_path = public, app as $$
  select coalesce(array_agg(distinct p order by p), '{}') from (
    select unnest(app.academy_paths_of_pre0931(p_user)) as p
    union all select app.fx_sales_path(p_user) where exists (select 1 from staff_profiles sp where sp.user_id = p_user and sp.sales_opt_in_at is not null and sp.is_active)) x
$$;
select pg_temp.copy_grants('app.academy_paths_of(uuid)'::regprocedure, 'app.academy_paths_of_pre0931(uuid)'::regprocedure);

alter function app.academy_done(uuid) rename to academy_done_pre0931;
create function app.academy_done(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select case when exists (select 1 from staff_profiles sp where sp.user_id = p_user and sp.sales_opt_in_at is not null)
    then not exists (select 1 from academy_path_sections ps where ps.path_code = any (app.academy_paths_of(p_user)) and ps.path_code not in ('sales_in_person', 'sales_remote')
                       and not app.academy_passed(p_user, ps.section_id))
    else app.academy_done_pre0931(p_user) end
$$;
select pg_temp.copy_grants('app.academy_done(uuid)'::regprocedure, 'app.academy_done_pre0931(uuid)'::regprocedure);

alter function app.my_roles(uuid) rename to my_roles_pre0931;
create function app.my_roles(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.my_roles_pre0931(p_user) || coalesce((select jsonb_build_object('sales_opt_in', true, 'sales_ready', 'sales' = any (sp.functions))
                                                     from staff_profiles sp where sp.user_id = p_user and sp.sales_opt_in_at is not null), '{}'::jsonb)
$$;
select pg_temp.copy_grants('app.my_roles(uuid)'::regprocedure, 'app.my_roles_pre0931(uuid)'::regprocedure);

-- ================================================================ 5. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0931;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if p_call = 'field_do' and p_name in ('shift_cancel', 'shift_drop', 'offer_claim', 'swap_ask', 'swap_answer', 'sales_optin') then
    perform app.door_begin(p_user, p_aal);
    if not app.is_field_person(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return case p_name
      when 'shift_cancel' then app.fx_shift_cancel(p_user, p_)
      when 'shift_drop' then app.fx_shift_cancel(p_user, p_)
      when 'offer_claim' then app.fx_offer_claim(p_user, p_)
      when 'swap_ask' then app.fx_swap_ask(p_user, p_)
      when 'swap_answer' then app.fx_swap_answer(p_user, p_)
      else app.fx_sales_optin(p_user, p_) end;
  end if;
  if p_call = 'field_read' and p_name = 'sales_state' then
    perform app.door_begin(p_user, p_aal);
    return app.fx_sales_state(p_user);
  end if;
  if (p_call in ('va_read', 'field_read') and p_name = 'my_pay_identity') or (p_call in ('va_do', 'field_do') and p_name = 'my_pay_identity_save') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'my_pay_identity' then app.pay_identity_view(p_user) else app.pay_identity_save(p_user, p_) end;
  end if;
  if (p_call = 'ops_read' and p_name = 'pay_identity_list') or (p_call = 'ops_do' and p_name = 'pay_identity_reveal') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'pay_identity_list' then app.pay_identity_list(p_user) else app.pay_identity_reveal(p_user, p_) end;
  end if;
  return app.door_pre0931(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0931(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and (p.proname like 'fx\_%' or p.proname like 'pay\_identity\_%'
              or p.proname in ('job_field_shift_offers', 'door_pre0931', 'field_staff_board_pre0931', 'field_my_shifts_pre0931', 'academy_paths_of_pre0931',
                               'academy_done_pre0931', 'my_roles_pre0931'))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
