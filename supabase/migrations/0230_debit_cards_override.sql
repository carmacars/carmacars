-- 0230: a credit card stays required, with an Admin's override per booking for a debit or prepaid card, a site-wide
-- default, and the card's type kept on each payment (docs/changes/2026-11-03-debit-card-override.md).
--
-- The owner, Release 23a: the Deposit must be on a credit card so the deductible can be charged, so a credit card stays
-- required by default (the pay page, staff pay links and the Deposit hold refuse a debit or prepaid card, card_not_credit,
-- as before; a car marked "no credit card needed" still takes debit, 0093).
--
-- 1. bookings.debit_allowed_*: an Admin may allow a debit or prepaid card for one booking (Money tab, "Allow debit and
--    prepaid cards for this booking", with a reason; who and when are kept; audited). Then that booking's pay page, staff
--    pay links and Deposit hold take one, and the renter is told the hold lowers the money available until it is
--    released.
-- 2. program_settings.card_types_accepted: credit (the default: as above) or any (credit, debit and prepaid on every
--    booking), so the owner can open it up later without a release.
-- 3. Never overridden: a booking on credit card rental coverage (coverage option 2) is paid on the credit card that
--    carries the coverage.
-- 4. payments.card_funding: credit, debit, prepaid or unknown, kept on each card payment (from its saved card, else the
--    renter's saved card with the same brand and last four digits); the Money tab lists the cards used with their type.
-- No applied migration is edited.

alter table program_settings add column if not exists card_types_accepted text not null default 'credit' check (card_types_accepted in ('credit', 'any'));
comment on column program_settings.card_types_accepted is 'Card types accepted (0230): credit (the default; a debit or prepaid card only on a booking an Admin allowed, or a car marked no credit card needed) or any (credit, debit and prepaid). Card coverage always needs its credit card.';

alter table bookings
  add column if not exists debit_allowed_at timestamptz,
  add column if not exists debit_allowed_by uuid references users(id) on delete set null,
  add column if not exists debit_allowed_reason text;
comment on column bookings.debit_allowed_at is 'An Admin allowed a debit or prepaid card for this booking (0230), with debit_allowed_by and debit_allowed_reason; never for card coverage.';

-- ================================================================ 1 to 3. the cards taken
-- 0093's rule (a car marked no credit card needed takes a credit or debit card), and now the Admin's override per booking
-- and the site-wide default; card coverage (option 2) never
create or replace function app.booking_card_ok(p_booking uuid, p_card jsonb) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce(p_card ->> 'funding', '') = 'credit'
      or (not coalesce((select b.coverage_option = 2 from bookings b where b.id = p_booking), false)
          and ((app.settings()).card_types_accepted = 'any'
               or exists (select 1 from bookings b where b.id = p_booking and b.debit_allowed_at is not null)
               or (coalesce((select v.no_credit_card from bookings b join vehicles v on v.id = b.vehicle_id where b.id = p_booking), false)
                   and coalesce(p_card ->> 'funding', 'debit') in ('credit', 'debit', 'unknown'))))
$$;
revoke all on function app.booking_card_ok(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.booking_card_ok(uuid, jsonb) to service_role;

-- whether the booking takes a debit or prepaid card (the pay page and the pay links say so, with the note on the hold)
create or replace function public.booking_takes_debit(p_booking uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.booking_card_ok(p_booking, '{"funding": "prepaid"}'::jsonb)
$$;
revoke all on function public.booking_takes_debit(uuid) from public, anon, authenticated;
grant execute on function public.booking_takes_debit(uuid) to service_role;

-- the Admin's override (Money tab): on with a reason, or off
create or replace function app.booking_allow_debit(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_on boolean := coalesce((p ->> 'allow')::boolean, true);
  v_reason text := nullif(btrim(p ->> 'reason'), '');
begin
  perform app.assert_admin(p_by);
  select * into b from bookings where id::text = p ->> 'booking_id' or booking_number = p ->> 'booking' for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if v_on and b.coverage_option = 2 then
    raise exception 'This booking is on credit card rental coverage: it is paid on the credit card that carries the coverage' using errcode = '23514';
  end if;
  if v_on and v_reason is null then raise exception 'Give the reason' using errcode = '22023'; end if;
  update bookings set debit_allowed_at = case when v_on then now() end, debit_allowed_by = case when v_on then p_by end,
         debit_allowed_reason = case when v_on then left(v_reason, 300) end, updated_at = now()
   where id = b.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, case when v_on then 'booking_allow_debit' else 'booking_disallow_debit' end, 'bookings', b.id::text,
          jsonb_build_object('debit_allowed_at', b.debit_allowed_at, 'reason', b.debit_allowed_reason),
          jsonb_build_object('debit_allowed', v_on, 'reason', v_reason));
  return jsonb_build_object('booking_id', b.id, 'debit_allowed', v_on);
end $$;
revoke all on function app.booking_allow_debit(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.booking_allow_debit(uuid, jsonb) to service_role;

-- ================================================================ 4. the card's type on the payment
alter table payments add column if not exists card_funding text check (card_funding is null or card_funding in ('credit', 'debit', 'prepaid', 'unknown'));
comment on column payments.card_funding is 'The card''s type (0230): credit, debit, prepaid or unknown, from its saved card.';

create or replace function app.payments_card_funding() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.card_funding is null and new.payment_method_id is not null then
    select coalesce(pm.funding, case when pm.is_credit then 'credit' end) into new.card_funding from payment_methods pm where pm.id = new.payment_method_id;
  end if;
  if new.card_funding is null and new.card_last4 is not null and new.renter_id is not null then
    select coalesce(pm.funding, case when pm.is_credit then 'credit' end) into new.card_funding from payment_methods pm
     where pm.renter_id = new.renter_id and pm.card_last4 = new.card_last4 and (new.card_brand is null or lower(pm.card_brand) = lower(new.card_brand))
     order by pm.created_at desc limit 1;
  end if;
  if new.card_funding is not null and new.card_funding not in ('credit', 'debit', 'prepaid', 'unknown') then new.card_funding := 'unknown'; end if;
  return new;
end $$;
revoke all on function app.payments_card_funding() from public, anon, authenticated;
grant execute on function app.payments_card_funding() to service_role;
drop trigger if exists payments_card_funding on payments;
create trigger payments_card_funding before insert or update of payment_method_id, card_last4, card_funding on payments
  for each row execute function app.payments_card_funding();

-- the payments made so far
update payments p set card_funding = coalesce(pm.funding, case when pm.is_credit then 'credit' end)
  from payment_methods pm where pm.id = p.payment_method_id and p.card_funding is null and coalesce(pm.funding, case when pm.is_credit then 'credit' end) is not null;

-- the Money tab: the cards used on the booking with their type, and the override
alter function app.booking_money(uuid, jsonb) rename to booking_money_pre0230;
create function app.booking_money(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := app.booking_money_pre0230(p_by, p);
  b bookings;
begin
  if v is null or nullif(v ->> 'booking_id', '') is null then return v; end if;
  select * into b from bookings where id = (v ->> 'booking_id')::uuid;
  return v || jsonb_build_object('cards', coalesce((
    select jsonb_agg(jsonb_build_object('brand', x.card_brand, 'last4', x.card_last4, 'funding', coalesce(x.card_funding, 'unknown'), 'payments', x.n, 'last_at', x.last_at) order by x.last_at desc)
      from (select py.card_brand, py.card_last4, max(py.card_funding) as card_funding, count(*) as n, max(py.created_at) as last_at
              from payments py where py.booking_id = b.id and py.card_last4 is not null and py.status <> 'failed'
             group by py.card_brand, py.card_last4) x), '[]'::jsonb),
    'debit', jsonb_build_object('allowed_at', b.debit_allowed_at, 'reason', b.debit_allowed_reason,
                                'by', (select u.full_name from users u where u.id = b.debit_allowed_by),
                                'takes', public.booking_takes_debit(b.id), 'coverage', coalesce(b.coverage_option = 2, false),
                                'site', (app.settings()).card_types_accepted));
end $$;
revoke all on function app.booking_money(uuid, jsonb) from public, anon, authenticated;
do $$
declare g text;
begin
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.booking_money_pre0230(uuid, jsonb)', 'execute') then execute format('grant execute on function app.booking_money(uuid, jsonb) to %I', g); end if;
  end loop;
end $$;
revoke all on function app.booking_money_pre0230(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.booking_money_pre0230(uuid, jsonb) to service_role;

-- ================================================================ the door: Admin only
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0230;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_do' and p_name = 'booking_allow_debit' then
    perform app.door_begin(p_user, p_aal);
    return app.booking_allow_debit(p_user, coalesce(p, '{}'::jsonb));
  end if;
  return app.door_pre0230(p_user, p_aal, p_call, p_name, p);
end $$;
do $$
declare g text;
begin
  execute 'revoke all on function app.door(uuid, text, text, text, jsonb) from public, anon, authenticated';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.door_pre0230(uuid, text, text, text, jsonb)', 'execute') then execute format('grant execute on function app.door(uuid, text, text, text, jsonb) to %I', g); end if;
  end loop;
end $$;
revoke all on function app.door_pre0230(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function app.door_pre0230(uuid, text, text, text, jsonb) to service_role;
