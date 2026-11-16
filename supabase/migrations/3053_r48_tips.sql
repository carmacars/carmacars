-- 3053 (release 48, part 2): tips (docs/changes/2026-11-15-r48-tips.md). On by default (program_settings.tips_on).
--
-- The renter adds a tip on the pay page (checkout), on the booking's receipt after the return, or from the link in the
-- after-trip email and text: 10, 15 or 20% of the rental total (program_settings.tip_percents_bps) or an amount they
-- type, paid by card on Stripe's own form (a payment request covering "tip"). Staff record a tip received in cash or by
-- e-Transfer (record_payment covers=tip, and the connector). A tip is money for the people, never the rental: it is no
-- line of the booking, so no owner revenue share, no statement and no HST; payments.purpose is 'tip'.
--
-- The split (tip_shares): half to the booking's salesperson (bookings.sales_staff_id) and half to the staff member who
-- did the pickup handover (the pickup check-in report's staff member, else the staff member who recorded the pickup).
-- No salesperson (a direct booking) or no staff handover (a self pickup): CarmaCars keeps that half as company revenue.
-- One person who did both gets all of it. An odd cent goes to the salesperson's half. An Admin may set another split for
-- one tip, with the reason (tip_split_set). Each person's share is on My sales and Field pay (my_tips); CarmaCars'
-- share and every tip are on Admin > Money (tips_report).
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

alter table program_settings add column if not exists tips_on boolean not null default true;
alter table program_settings add column if not exists tip_percents_bps integer[] not null default array[1000, 1500, 2000];
alter table program_settings add column if not exists tip_sales_share_bps integer not null default 5000 check (tip_sales_share_bps between 0 and 10000);
comment on column program_settings.tips_on is 'Tips (3053): renters may add a tip at checkout, on the receipt and from the after-trip link; staff record cash and e-Transfer tips.';
comment on column program_settings.tip_percents_bps is 'Tips (3053): the percentages offered, of the rental total, in hundredths of a percent (1000 is 10%).';
comment on column program_settings.tip_sales_share_bps is 'Tips (3053): the salesperson''s share; the rest goes to the staff member who did the handover (5000: 50/50).';

alter table payments drop constraint payments_purpose_check;
alter table payments add constraint payments_purpose_check check (purpose = any (array['booking_total', 'deposit', 'extension', 'post_rental',
  'toll_ticket', 'damage', 'deductible', 'owner_upfront', 'owner_fees', 'other', 'addon', 'tip']));
alter table manual_payments drop constraint manual_payments_covers_check;
alter table manual_payments add constraint manual_payments_covers_check check (covers = any (array['rental', 'deposit', 'fees', 'later', 'tip']));
alter table payment_requests drop constraint payment_requests_covers_check;
alter table payment_requests add constraint payment_requests_covers_check
  check (covers in ('rental', 'deposit', 'fees', 'later', 'card', 'balance', 'extension', 'tip'));

create table if not exists tips (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references bookings(id),
  amount_cents bigint not null check (amount_cents > 0),
  percent_bps integer check (percent_bps is null or percent_bps between 1 and 10000),
  method text not null check (method in ('card', 'cash', 'e_transfer')),
  source text not null check (source in ('checkout', 'receipt', 'link', 'staff')),
  status text not null default 'pending' check (status in ('pending', 'paid', 'voided', 'cancelled')),
  payment_id uuid references payments(id),
  payment_request_id uuid references payment_requests(id),
  reference text,
  received_on date,
  note text check (note is null or length(note) <= 500),
  recorded_by uuid references users(id),
  split_by uuid references users(id),
  split_reason text,
  split_at timestamptz,
  paid_at timestamptz,
  voided_at timestamptz,
  void_reason text,
  created_at timestamptz not null default now(),
  check ((status = 'paid') = (paid_at is not null))
);
create index if not exists tips_booking_idx on tips (booking_id);
create index if not exists tips_payment_idx on tips (payment_id);
create index if not exists tips_payment_request_idx on tips (payment_request_id);
comment on table tips is 'A tip on a booking (3053): by card from the renter, or cash or e-Transfer recorded by staff. Never a line of the booking.';

create table if not exists tip_shares (
  id uuid primary key default gen_random_uuid(),
  tip_id uuid not null references tips(id) on delete cascade,
  staff_id uuid references users(id),
  role text not null check (role in ('sales', 'handover', 'both', 'company', 'override')),
  amount_cents bigint not null check (amount_cents >= 0),
  created_at timestamptz not null default now(),
  check ((role = 'company') = (staff_id is null) or role = 'override')
);
create index if not exists tip_shares_tip_idx on tip_shares (tip_id);
create index if not exists tip_shares_staff_idx on tip_shares (staff_id);
comment on table tip_shares is 'Who a tip goes to (3053): the salesperson, the handover, both, CarmaCars (staff_id null), or an Admin''s split.';

alter table tips enable row level security;
alter table tip_shares enable row level security;
create policy admin_all on tips for select to authenticated using (app.is_admin());
create policy admin_all on tip_shares for select to authenticated using (app.is_admin());
revoke all on tips, tip_shares from anon, authenticated;
grant select on tips, tip_shares to authenticated;
grant all on tips, tip_shares to service_role;

-- ================================================================ who gets it
create or replace function app.is_staff(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is not null and exists (select 1 from user_roles r where r.user_id = p_user and r.role in ('admin', 'va', 'field'))
$$;
revoke all on function app.is_staff(uuid) from public, anon, authenticated;
grant execute on function app.is_staff(uuid) to service_role;

-- the staff member who did the pickup handover: the pickup check-in report, else who recorded the pickup
create or replace function app.booking_handover_staff(p_booking uuid) returns uuid
language sql stable security definer set search_path = public, app as $$
  select coalesce(
    (select c.performed_by from condition_reports c where c.booking_id = p_booking and c.kind = 'pickup' and app.is_staff(c.performed_by)
      order by c.performed_at desc nulls last limit 1),
    (select e.actor_user_id from booking_events e where e.booking_id = p_booking and e.to_status = 'on_rent' and app.is_staff(e.actor_user_id)
      order by e.created_at desc limit 1))
$$;
revoke all on function app.booking_handover_staff(uuid) from public, anon, authenticated;
grant execute on function app.booking_handover_staff(uuid) to service_role;

-- the default split of a tip, written as its shares (an Admin's split is kept)
create or replace function app.tip_split(p_tip uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  t tips;
  v_sales uuid;
  v_hand uuid;
  v_s bigint;
begin
  select * into t from tips where id = p_tip;
  if t.id is null or t.status <> 'paid' or t.split_by is not null then return; end if;
  delete from tip_shares where tip_id = t.id;
  select case when app.is_staff(b.sales_staff_id) then b.sales_staff_id end into v_sales from bookings b where b.id = t.booking_id;
  v_hand := app.booking_handover_staff(t.booking_id);
  if v_sales is not null and v_sales = v_hand then
    insert into tip_shares (tip_id, staff_id, role, amount_cents) values (t.id, v_sales, 'both', t.amount_cents);
    return;
  end if;
  v_s := t.amount_cents - (t.amount_cents * (10000 - coalesce((app.settings()).tip_sales_share_bps, 5000)) / 10000);
  insert into tip_shares (tip_id, staff_id, role, amount_cents)
  values (t.id, v_sales, case when v_sales is null then 'company' else 'sales' end, v_s),
         (t.id, v_hand, case when v_hand is null then 'company' else 'handover' end, t.amount_cents - v_s);
end $$;
revoke all on function app.tip_split(uuid) from public, anon, authenticated;
grant execute on function app.tip_split(uuid) to service_role;

-- a tip paid: its shares, the booking's history, the renter's receipt
create or replace function app.tip_paid(p_tip uuid, p_payment uuid, p_by uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  t tips;
  b bookings;
begin
  update tips set status = 'paid', paid_at = now(), payment_id = p_payment where id = p_tip and status = 'pending' returning * into t;
  if t.id is null then return; end if;
  select * into b from bookings where id = t.booking_id;
  perform app.tip_split(t.id);
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version,
    format('Tip of %s by %s. Thank you!', app.fmt_money(t.amount_cents), app.payment_method_label(t.method)), p_by,
    case when app.is_staff(p_by) then 'staff' else 'renter' end, jsonb_build_object('tip_id', t.id, 'payment_id', p_payment));
  perform app.ntf_emit('renter_payment_receipt', 'payment', p_payment, 'succeeded', jsonb_build_object('booking_id', b.id, 'renter_id', b.renter_id));
end $$;
revoke all on function app.tip_paid(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function app.tip_paid(uuid, uuid, uuid) to service_role;

-- the tip suggestions of a booking: the percentages of its rental total, and whether it may take one
create or replace function app.tip_options(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'on', coalesce((app.settings()).tips_on, true) and b.booking_type <> 'owner'
          and b.status::text in ('pending_payment', 'confirmed', 'on_rent', 'returned', 'closed'),
    'base_cents', coalesce(b.renter_due_at_booking_cents, b.total_due_at_booking_cents, 0),
    'options', (select coalesce(jsonb_agg(jsonb_build_object('percent_bps', x, 'cents', round(coalesce(b.renter_due_at_booking_cents, b.total_due_at_booking_cents, 0) * x / 10000.0)::bigint) order by o), '[]'::jsonb)
                  from unnest(coalesce((app.settings()).tip_percents_bps, array[1000, 1500, 2000])) with ordinality u(x, o)),
    'paid', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'amount_cents', t.amount_cents, 'method', t.method, 'paid_at', t.paid_at) order by t.paid_at), '[]'::jsonb)
               from tips t where t.booking_id = b.id and t.status = 'paid'),
    'paid_cents', (select coalesce(sum(t.amount_cents), 0) from tips t where t.booking_id = b.id and t.status = 'paid'))
    from bookings b where b.id = p_booking
$$;
revoke all on function app.tip_options(uuid) from public, anon, authenticated;
grant execute on function app.tip_options(uuid) to service_role;
create or replace function public.server_tip_options(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.tip_options(p_booking) $$;
revoke all on function public.server_tip_options(uuid) from public, anon, authenticated;
grant execute on function public.server_tip_options(uuid) to service_role;

-- ================================================================ staff record a tip (record_payment covers=tip)
create or replace function app.record_tip(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_method text := coalesce(nullif(p ->> 'method', ''), 'cash');
  v_amount bigint := nullif(p ->> 'amount_cents', '')::bigint;
  v_ref text := nullif(btrim(coalesce(p ->> 'reference', '')), '');
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  v_on date := coalesce(nullif(p ->> 'received_on', '')::date, app.today());
  v_refuse text;
  v_pay uuid;
  v_tip uuid;
begin
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if not coalesce((app.settings()).tips_on, true) then raise exception 'Tips are off (Program settings)' using errcode = '23514'; end if;
  if b.booking_type = 'owner' or b.status::text not in ('pending_payment', 'confirmed', 'on_rent', 'returned', 'closed') then
    raise exception 'Booking % is %: a tip is taken on a booking that is paid, out or back', b.booking_number, replace(b.status::text, '_', ' ') using errcode = '23514';
  end if;
  if v_method not in ('cash', 'e_transfer') then raise exception 'A tip recorded by staff is cash or e-Transfer; a card tip is added by the renter' using errcode = '22023'; end if;
  if v_amount is null or v_amount <= 0 then raise exception 'Enter the amount of the tip' using errcode = '22023'; end if;
  v_refuse := app.booking_payment_allowed(p_by, v_amount);
  if v_refuse is not null then raise exception '%', v_refuse using errcode = '42501'; end if;
  if v_method = 'e_transfer' and (v_ref is null or length(v_ref) < 3) then raise exception 'Enter the e-Transfer reference number' using errcode = '22023'; end if;
  if v_on > app.today() then raise exception 'The date received cannot be in the future' using errcode = '22023'; end if;
  if v_ref is not null then
    select t.id into v_tip from tips t where t.booking_id = b.id and t.method = v_method and lower(t.reference) = lower(v_ref) and t.status = 'paid';
    if v_tip is not null then return jsonb_build_object('ok', true, 'repeat', true, 'tip_id', v_tip); end if;
  end if;
  insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at, created_by)
  values (b.id, b.renter_id, 'tip', 'charge', v_method, v_amount, 'succeeded', app.local_midnight(v_on) + interval '12 hours', p_by)
  returning id into v_pay;
  insert into payment_processor_details (payment_id, processor, processor_payment_id, raw)
  values (v_pay, 'offline', v_method || ':' || coalesce(v_ref, v_pay::text), jsonb_strip_nulls(jsonb_build_object('reference', v_ref, 'received_on', v_on, 'note', v_note, 'recorded_by', p_by, 'covers', 'tip')));
  insert into manual_payments (payment_id, target, booking_id, renter_id, method, amount_cents, received_on, reference, note, recorded_by, covers)
  values (v_pay, 'booking', b.id, b.renter_id, v_method, v_amount, v_on, v_ref, v_note, p_by, 'tip');
  insert into tips (booking_id, amount_cents, method, source, reference, received_on, note, recorded_by)
  values (b.id, v_amount, v_method, 'staff', v_ref, v_on, v_note, p_by) returning id into v_tip;
  perform app.tip_paid(v_tip, v_pay, p_by);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'record_tip', 'bookings', b.id::text, jsonb_build_object('tip_id', v_tip, 'payment_id', v_pay, 'method', v_method, 'amount_cents', v_amount, 'reference', v_ref));
  return jsonb_build_object('ok', true, 'tip_id', v_tip, 'payment_id', v_pay, 'amount_cents', v_amount,
    'shares', (select jsonb_agg(jsonb_build_object('staff_id', s.staff_id, 'role', s.role, 'amount_cents', s.amount_cents) order by s.role) from tip_shares s where s.tip_id = v_tip));
end $$;
revoke all on function app.record_tip(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.record_tip(uuid, jsonb) to service_role;

alter function app.record_booking_payment(uuid, jsonb) rename to record_booking_payment_pre3053;
create function app.record_booking_payment(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p ->> 'covers' = 'tip' then return app.record_tip(p_by, p); end if;
  return app.record_booking_payment_pre3053(p_by, p);
end $$;
select pg_temp.copy_grants('app.record_booking_payment(uuid, jsonb)'::regprocedure, 'app.record_booking_payment_pre3053(uuid, jsonb)'::regprocedure);

-- a tip recorded by hand and voided: the tip and its shares are voided with it
create or replace function app.tip_follow_void() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.voided_at is not null and old.voided_at is null and new.covers = 'tip' then
    update tips set status = 'voided', voided_at = new.voided_at, void_reason = new.void_reason, paid_at = null where payment_id = new.payment_id and status = 'paid';
  end if;
  return new;
end $$;
revoke all on function app.tip_follow_void() from public, anon, authenticated;
drop trigger if exists manual_payments_tip_void on manual_payments;
create trigger manual_payments_tip_void after update of voided_at on manual_payments for each row execute function app.tip_follow_void();

-- ================================================================ an Admin's split of one tip
create or replace function app.tip_split_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  t tips;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  s jsonb;
  v_sum bigint := 0;
begin
  perform app.assert_admin(p_by);
  select * into t from tips where id::text = p ->> 'tip' for update;
  if t.id is null then raise exception 'Tip not found' using errcode = 'P0002'; end if;
  if t.status <> 'paid' then raise exception 'This tip is not paid' using errcode = '23514'; end if;
  if coalesce((p ->> 'reset')::boolean, false) then
    update tips set split_by = null, split_reason = null, split_at = null where id = t.id;
    perform app.tip_split(t.id);
    return jsonb_build_object('ok', true, 'tip_id', t.id, 'reset', true);
  end if;
  if v_reason is null then raise exception 'Give the reason for the split' using errcode = '22023'; end if;
  if jsonb_typeof(p -> 'shares') <> 'array' or jsonb_array_length(p -> 'shares') = 0 then raise exception 'List who gets what' using errcode = '22023'; end if;
  for s in select * from jsonb_array_elements(p -> 'shares') loop
    if nullif(s ->> 'staff_id', '') is not null and not app.is_staff((s ->> 'staff_id')::uuid) then raise exception 'A share goes to a staff member or to CarmaCars' using errcode = '22023'; end if;
    if coalesce((s ->> 'amount_cents')::bigint, -1) < 0 then raise exception 'Each share is an amount of 0 or more' using errcode = '22023'; end if;
    v_sum := v_sum + (s ->> 'amount_cents')::bigint;
  end loop;
  if v_sum <> t.amount_cents then raise exception 'The shares add up to %, not the tip of %', app.fmt_money(v_sum), app.fmt_money(t.amount_cents) using errcode = '22023'; end if;
  delete from tip_shares where tip_id = t.id;
  insert into tip_shares (tip_id, staff_id, role, amount_cents)
  select t.id, nullif(x ->> 'staff_id', '')::uuid, case when nullif(x ->> 'staff_id', '') is null then 'company' else 'override' end, (x ->> 'amount_cents')::bigint
    from jsonb_array_elements(p -> 'shares') x where (x ->> 'amount_cents')::bigint > 0;
  update tips set split_by = p_by, split_reason = v_reason, split_at = now() where id = t.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'tip_split_set', 'tips', t.id::text, jsonb_build_object('shares', p -> 'shares', 'reason', v_reason));
  return jsonb_build_object('ok', true, 'tip_id', t.id);
end $$;
revoke all on function app.tip_split_set(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.tip_split_set(uuid, jsonb) to service_role;

-- ================================================================ the reads
-- a staff member's own shares (My sales, Field pay): this month and the last 90 days
create or replace function app.my_tips(p_by uuid, p jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'month_cents', coalesce((select sum(s.amount_cents) from tip_shares s join tips t on t.id = s.tip_id
                               where s.staff_id = p_by and t.status = 'paid' and t.paid_at >= date_trunc('month', now() at time zone 'America/Toronto') at time zone 'America/Toronto'), 0),
    'total_cents', coalesce((select sum(s.amount_cents) from tip_shares s join tips t on t.id = s.tip_id where s.staff_id = p_by and t.status = 'paid'), 0),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('tip_id', t.id, 'booking_number', b.booking_number, 'paid_at', t.paid_at, 'tip_cents', t.amount_cents,
                        'method', t.method, 'role', s.role, 'share_cents', s.amount_cents) order by t.paid_at desc)
                       from tip_shares s join tips t on t.id = s.tip_id join bookings b on b.id = t.booking_id
                      where s.staff_id = p_by and t.status = 'paid' and t.paid_at >= now() - interval '90 days'), '[]'::jsonb))
$$;
revoke all on function app.my_tips(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.my_tips(uuid, jsonb) to service_role;

-- Admin > Money: every tip of a period, its shares, CarmaCars' share and each person's
create or replace function app.tips_report(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_from timestamptz := coalesce(nullif(p ->> 'from', '')::date, (date_trunc('month', now() at time zone 'America/Toronto'))::date)::timestamp at time zone 'America/Toronto';
  v_to timestamptz := (coalesce(nullif(p ->> 'to', '')::date, app.today()) + 1)::timestamp at time zone 'America/Toronto';
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object(
    'from', v_from, 'to', v_to,
    'total_cents', coalesce((select sum(t.amount_cents) from tips t where t.status = 'paid' and t.paid_at >= v_from and t.paid_at < v_to), 0),
    'company_cents', coalesce((select sum(s.amount_cents) from tip_shares s join tips t on t.id = s.tip_id where s.staff_id is null and t.status = 'paid' and t.paid_at >= v_from and t.paid_at < v_to), 0),
    'by_staff', coalesce((select jsonb_agg(x order by x ->> 'name') from (
        select jsonb_build_object('staff_id', s.staff_id, 'name', coalesce(u.full_name, u.email), 'cents', sum(s.amount_cents), 'tips', count(*)) x
          from tip_shares s join tips t on t.id = s.tip_id join users u on u.id = s.staff_id
         where t.status = 'paid' and t.paid_at >= v_from and t.paid_at < v_to group by s.staff_id, u.full_name, u.email) y), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('tip_id', t.id, 'booking_number', b.booking_number, 'paid_at', t.paid_at, 'amount_cents', t.amount_cents,
                        'method', t.method, 'source', t.source, 'split_by_admin', t.split_by is not null, 'split_reason', t.split_reason,
                        'shares', (select jsonb_agg(jsonb_build_object('staff_id', s.staff_id, 'name', coalesce(u.full_name, 'CarmaCars'), 'role', s.role, 'amount_cents', s.amount_cents) order by s.role)
                                     from tip_shares s left join users u on u.id = s.staff_id where s.tip_id = t.id)) order by t.paid_at desc)
                       from tips t join bookings b on b.id = t.booking_id where t.status = 'paid' and t.paid_at >= v_from and t.paid_at < v_to), '[]'::jsonb));
end $$;
revoke all on function app.tips_report(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.tips_report(uuid, jsonb) to service_role;

-- the Money tab: the booking's tips and who gets them
alter function app.booking_money(uuid, jsonb) rename to booking_money_pre3053;
create function app.booking_money(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := app.booking_money_pre3053(p_by, p);
  v_b uuid;
begin
  if v is null or nullif(v ->> 'booking_id', '') is null then return v; end if;
  v_b := (v ->> 'booking_id')::uuid;
  return v || jsonb_build_object('tips', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'amount_cents', t.amount_cents, 'method', t.method, 'source', t.source,
      'status', t.status, 'paid_at', t.paid_at, 'reference', t.reference, 'split_by_admin', t.split_by is not null,
      'shares', (select jsonb_agg(jsonb_build_object('staff_id', s.staff_id, 'name', coalesce(u.full_name, 'CarmaCars'), 'role', s.role, 'amount_cents', s.amount_cents) order by s.role)
                   from tip_shares s left join users u on u.id = s.staff_id where s.tip_id = t.id)) order by t.created_at)
      from tips t where t.booking_id = v_b and t.status in ('paid', 'voided')), '[]'::jsonb),
    'tips_on', coalesce((app.settings()).tips_on, true));
end $$;
select pg_temp.copy_grants('app.booking_money(uuid, jsonb)'::regprocedure, 'app.booking_money_pre3053(uuid, jsonb)'::regprocedure);

-- ================================================================ the renter's tip by card (Stripe's own form)
create or replace function public.renter_tip_payreq(p_booking uuid, p_by uuid, p_amount bigint, p_percent_bps integer, p_source text, p_token_sha256 text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_id uuid;
  v_tip uuid;
  o jsonb := app.tip_options(p_booking);
begin
  perform app.assert_booking_renter(p_booking, p_by);
  select * into b from bookings where id = p_booking;
  if not coalesce((o ->> 'on')::boolean, false) then raise exception 'A tip cannot be added to this booking.' using errcode = '23514'; end if;
  if p_source not in ('checkout', 'receipt', 'link') then raise exception 'Where the tip is added is missing' using errcode = '22023'; end if;
  if p_amount is null or p_amount < 100 then raise exception 'A tip is $1 or more.' using errcode = '22023'; end if;
  if p_amount > greatest(100000, coalesce((o ->> 'base_cents')::bigint, 0)) then raise exception 'That tip is more than the booking itself: check the amount.' using errcode = '22023'; end if;
  if p_token_sha256 is null or p_token_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'The link token is missing' using errcode = '22023'; end if;
  -- one open tip link at a time
  update payment_requests set status = 'cancelled', last_error = coalesce(last_error, 'Replaced by a new tip') where booking_id = b.id and covers = 'tip' and status = 'open';
  update tips set status = 'cancelled' where booking_id = b.id and status = 'pending' and method = 'card';
  insert into payment_requests (booking_id, renter_id, kind, covers, amount_cents, reason, token_sha256, channel, expires_at, created_by)
  values (b.id, b.renter_id, 'charge', 'tip', p_amount, 'a tip for the CarmaCars team (booking ' || b.booking_number || ')', p_token_sha256, 'link', now() + interval '1 day', p_by)
  returning id into v_id;
  insert into tips (booking_id, amount_cents, percent_bps, method, source, payment_request_id)
  values (b.id, p_amount, nullif(p_percent_bps, 0), 'card', p_source, v_id) returning id into v_tip;
  return jsonb_build_object('id', v_id, 'tip_id', v_tip, 'kind', 'charge', 'covers', 'tip', 'amount_cents', p_amount, 'booking_id', b.id, 'booking_number', b.booking_number,
    'renter', (select jsonb_build_object('id', r.id, 'legal_name', r.legal_name, 'email', coalesce(r.email, u.email), 'mobile', r.mobile,
                 'customer_id', (select sc.processor_customer_id from payment_methods pm join payment_method_secrets sc on sc.payment_method_id = pm.id
                                  where pm.renter_id = r.id and sc.processor_customer_id is not null order by pm.created_at desc limit 1))
                 from renters r left join users u on u.id = r.user_id where r.id = b.renter_id));
end $$;
revoke all on function public.renter_tip_payreq(uuid, uuid, bigint, integer, text, text) from public, anon, authenticated;
grant execute on function public.renter_tip_payreq(uuid, uuid, bigint, integer, text, text) to service_role;

alter function public.server_payreq_settle(uuid, jsonb) rename to server_payreq_settle_pre3053;
create function public.server_payreq_settle(p_id uuid, p_intent jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  q payment_requests;
  b bookings;
  t tips;
  v_pay uuid;
begin
  select * into q from payment_requests where id = p_id for update;
  if q.id is null or q.covers <> 'tip' then return public.server_payreq_settle_pre3053(p_id, p_intent); end if;
  if q.status = 'paid' then return jsonb_build_object('ok', true, 'repeat', true, 'payment_id', q.payment_id); end if;
  if q.processor_intent_id is distinct from p_intent ->> 'id' then raise exception 'That payment is not this request''s' using errcode = '22023'; end if;
  if p_intent ->> 'status' not in ('succeeded', 'requires_capture') then
    update payment_requests set last_error = left(coalesce(p_intent ->> 'error', p_intent ->> 'status'), 300) where id = q.id;
    return jsonb_build_object('ok', false, 'reason', coalesce(p_intent ->> 'error', 'The payment did not go through'));
  end if;
  select * into b from bookings where id = q.booking_id;
  select * into t from tips where payment_request_id = q.id;
  insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at, card_brand, card_last4, card_funding)
  values (b.id, b.renter_id, 'tip', 'charge', 'card', coalesce((p_intent ->> 'amount')::bigint, q.amount_cents), 'succeeded', now(),
          p_intent -> 'card' ->> 'brand', p_intent -> 'card' ->> 'last4', case when p_intent -> 'card' ->> 'funding' in ('credit', 'debit', 'prepaid') then p_intent -> 'card' ->> 'funding' else null end)
  returning id into v_pay;
  insert into payment_processor_details (payment_id, processor, processor_payment_id, raw)
  values (v_pay, 'stripe', p_intent ->> 'id', jsonb_strip_nulls(jsonb_build_object('charge_id', p_intent ->> 'charge_id', 'covers', 'tip', 'status', p_intent ->> 'status')));
  update payment_requests set status = 'paid', completed_at = now(), payment_id = v_pay where id = q.id;
  if t.id is not null then
    update tips set status = 'pending', amount_cents = coalesce((p_intent ->> 'amount')::bigint, t.amount_cents) where id = t.id and status in ('pending', 'cancelled');
    perform app.tip_paid(t.id, v_pay, q.created_by);
  end if;
  return jsonb_build_object('ok', true, 'payment_id', v_pay, 'tip_id', t.id, 'capture', p_intent ->> 'status' = 'requires_capture');
end $$;
select pg_temp.copy_grants('public.server_payreq_settle(uuid, jsonb)'::regprocedure, 'public.server_payreq_settle_pre3053(uuid, jsonb)'::regprocedure);

-- ================================================================ the doors
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3053;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('va_read', 'field_read', 'ops_read', 'admin_read') and p_name = 'my_tips' then
    perform app.door_begin(p_user, p_aal);
    if not app.is_staff(p_user) then raise exception 'Staff only' using errcode = '42501'; end if;
    return app.my_tips(p_user, coalesce(p, '{}'::jsonb));
  elsif p_call = 'admin_read' and p_name = 'tips_report' then
    perform app.door_begin(p_user, p_aal);
    return app.tips_report(p_user, coalesce(p, '{}'::jsonb));
  elsif p_call in ('admin_do', 'ops_do') and p_name = 'tip_split_set' then
    perform app.door_begin(p_user, p_aal);
    return app.tip_split_set(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre3053(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3053(uuid, text, text, text, jsonb)'::regprocedure);
