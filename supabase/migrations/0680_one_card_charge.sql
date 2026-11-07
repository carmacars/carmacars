-- 0680: one charge of the card on file for the rental and the fees (docs/changes/2026-11-07-r32-booking-flows.md, item 2).
--
-- The Money tab's "The rental and fees" charged the saved card once per part: two Stripe charges, two receipts. Now one
-- charge of the card for what is open (covers 'balance'), split inside the database across the rental and the fees, the
-- rental first (the same order a pay link of the balance and a card payment of the whole booking already follow in
-- app.booking_part_open). What the rental and the fees leave open already leaves out the insurer's part and what was
-- paid another way (cash, e-Transfer: manual_payments), so neither is charged. Commissions and owner payouts follow the
-- rental part as before (the payment is a booking-total card payment, the rental first, as every saved-card charge of
-- the rental). The split of each such charge is kept in payment_part_allocations; the Money tab lists the one payment
-- as "Rental and fees" with both amounts, and Stripe's one receipt says "Rental $x and fees $y".
--   A charge of the rental or of the fees alone, with no amount, is for what that part has open.
-- Pay links of the balance (payment_requests.covers 'balance') were already one charge (0139); deposit holds and their
-- capture are one charge each. No applied migration is edited.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

create table if not exists payment_part_allocations (
  payment_id   uuid not null references payments (id) on delete cascade,
  part         text not null check (part in ('rental', 'fees')),
  amount_cents bigint not null check (amount_cents > 0),
  created_at   timestamptz not null default now(),
  primary key (payment_id, part)
);
alter table payment_part_allocations enable row level security;
create policy admin_all on payment_part_allocations for all to authenticated using (app.is_admin()) with check (app.is_admin());
comment on table payment_part_allocations is 'How one charge of the card on file for the rental and the fees is split across the two parts, the rental first (0680).';

-- the split of an amount across what the rental and the fees have open: the rental first
create or replace function app.balance_split(p_booking uuid, p_amount bigint) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_r bigint := app.booking_part_open(p_booking, 'rental');
  v_f bigint := app.booking_part_open(p_booking, 'fees');
  v_rental bigint := least(greatest(coalesce(p_amount, 0), 0), v_r);
begin
  return jsonb_build_object('rental', v_rental, 'fees', least(greatest(coalesce(p_amount, 0), 0) - v_rental, v_f), 'open', v_r + v_f);
end $$;

alter function app.card_charge_begin(uuid, jsonb) rename to card_charge_begin_pre0680;
create function app.card_charge_begin(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_covers text := coalesce(nullif(p ->> 'covers', ''), 'later');
  v_amount bigint := nullif(p ->> 'amount_cents', '')::bigint;
  v_split jsonb;
  v_reason text;
  v_out jsonb;
begin
  if v_covers not in ('rental', 'fees', 'balance') then return app.card_charge_begin_pre0680(p_by, p); end if;
  if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin charges a saved card' using errcode = '42501'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if v_covers <> 'balance' then
    -- one part: what it has open when no amount is given
    return app.card_charge_begin_pre0680(p_by, p || jsonb_build_object('amount_cents', coalesce(v_amount, app.booking_part_open(b.id, v_covers))));
  end if;
  v_split := app.balance_split(b.id, coalesce(v_amount, app.booking_part_open(b.id, 'rental') + app.booking_part_open(b.id, 'fees')));
  if (v_split ->> 'open')::bigint <= 0 then raise exception 'Nothing is open for the rental and the fees' using errcode = '23514'; end if;
  v_amount := coalesce(v_amount, (v_split ->> 'open')::bigint);
  if v_amount > (v_split ->> 'open')::bigint then
    raise exception 'The rental and the fees have % open: charge that much or less (a later charge for anything else)', app.fmt_money((v_split ->> 'open')::bigint) using errcode = '22023';
  end if;
  v_reason := concat_ws(' and ', case when (v_split ->> 'rental')::bigint > 0 then 'Rental ' || app.fmt_money((v_split ->> 'rental')::bigint) end,
                                 case when (v_split ->> 'fees')::bigint > 0 then 'fees ' || app.fmt_money((v_split ->> 'fees')::bigint) end);
  -- one booking-total charge of the card (the 0129 path, as a charge of the rental), then its split
  v_out := app.card_charge_begin_pre0680(p_by, p || jsonb_build_object('covers', 'rental', 'amount_cents', v_amount, 'reason', v_reason));
  insert into payment_part_allocations (payment_id, part, amount_cents)
  select (v_out ->> 'payment_id')::uuid, k, (v_split ->> k)::bigint from unnest(array['rental', 'fees']) k where (v_split ->> k)::bigint > 0;
  return v_out || jsonb_build_object('covers', 'balance', 'reason', v_reason,
    'parts', jsonb_build_object('rental', (v_split ->> 'rental')::bigint, 'fees', (v_split ->> 'fees')::bigint));
end $$;
select pg_temp.copy_grants('app.card_charge_begin(uuid, jsonb)'::regprocedure, 'app.card_charge_begin_pre0680(uuid, jsonb)'::regprocedure);

-- the Money tab: the one payment for the rental and the fees, with both amounts
alter function app.booking_money(uuid, jsonb) rename to booking_money_pre0680;
create function app.booking_money(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := app.booking_money_pre0680(p_user, p);
begin
  if v is null or jsonb_typeof(v -> 'payments') <> 'array' then return v; end if;
  return jsonb_set(v, '{payments}', coalesce((
    select jsonb_agg(case when a.parts is null then x else x || jsonb_build_object('covers', 'balance', 'parts', a.parts) end order by o)
      from jsonb_array_elements(v -> 'payments') with ordinality t(x, o)
      left join lateral (select jsonb_object_agg(pa.part, pa.amount_cents) parts from payment_part_allocations pa where pa.payment_id::text = x ->> 'id') a on true), '[]'::jsonb));
end $$;
select pg_temp.copy_grants('app.booking_money(uuid, jsonb)'::regprocedure, 'app.booking_money_pre0680(uuid, jsonb)'::regprocedure);

revoke all on function app.balance_split(uuid, bigint) from public, anon, authenticated;
grant execute on function app.balance_split(uuid, bigint) to service_role;
