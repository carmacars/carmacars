-- 0203: a card-coverage rental is paid on the same card (Release 21, item 4). SCHEMA_MARKER 0203.
-- docs/changes/2026-10-31-card-coverage-same-card.md.
--   When the renter's coverage is their credit card (coverage option 2), the whole rental (the rental and its fees) is
--   paid on that card: the card of the coverage proof, else the Card on File, else the first card that paid. A card is
--   the same when Stripe's card fingerprint matches; a card typed by hand (Record card payment) is checked by its last 4
--   digits and the staff member confirms it is the same card. Anything else is refused with the reason: another card on
--   the pay page (refunded at once), on the reader (cancelled before it is captured), or a payment by e-Transfer, cash and
--   the like. An Admin may allow another card or method for one booking, with the reason. Deposits and later charges are
--   not the rental: any card pays them.
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

create table booking_card_overrides (
  booking_id  uuid primary key references bookings (id),
  reason      text not null check (length(btrim(reason)) >= 10),
  created_by  uuid not null references users (id),
  created_at  timestamptz not null default now()
);
comment on table booking_card_overrides is 'An Admin allowed a card-coverage rental to be paid on another card or another way (0203), with the reason.';
alter table booking_card_overrides enable row level security;
create policy admin_all on booking_card_overrides to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger audit_booking_card_overrides after insert or update or delete on booking_card_overrides for each row execute function app.audit_row();

-- The card the rental must be paid on: required (a card-coverage rental), overridden, and the card (brand, last 4,
-- fingerprint) when one is known.
create function app.card_coverage_ref(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  v_pm uuid;
  pm payment_methods;
  v_fp text;
  v_brand text;
  v_last4 text;
  o booking_card_overrides;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null or coalesce(b.coverage_option, 0) <> 2 or b.booking_type = 'owner' then return jsonb_build_object('required', false); end if;
  select * into o from booking_card_overrides where booking_id = b.id;
  v_pm := coalesce((select cp.payment_method_id from coverage_proofs cp where cp.booking_id = b.id and cp.coverage_option = 2 and cp.status <> 'rejected' and cp.payment_method_id is not null
                     order by cp.created_at desc limit 1), b.card_on_file_id);
  select * into pm from payment_methods where id = v_pm;
  select s.fingerprint into v_fp from payment_method_secrets s where s.payment_method_id = v_pm;
  if pm.id is null then
    -- no card saved yet: the first card that paid the rental
    select p.card_brand, p.card_last4 into v_brand, v_last4 from payments p
     where p.booking_id = b.id and p.method = 'card' and p.kind = 'charge' and p.purpose = 'booking_total' and p.status = 'succeeded' and p.card_last4 is not null
     order by p.created_at limit 1;
  end if;
  return jsonb_build_object('required', true, 'overridden', o.booking_id is not null, 'override_reason', o.reason,
    'payment_method_id', pm.id, 'brand', coalesce(pm.card_brand, v_brand), 'last4', coalesce(pm.card_last4, v_last4), 'fingerprint', v_fp);
end $$;

-- null when this card may pay the rental of the booking, else the reason
create function app.card_coverage_same_card(p_booking uuid, p_fingerprint text, p_last4 text) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  r jsonb := app.card_coverage_ref(p_booking);
  v_same boolean;
begin
  if not (r ->> 'required')::boolean or coalesce((r ->> 'overridden')::boolean, false) then return null; end if;
  if (r ->> 'last4') is null and (r ->> 'fingerprint') is null then return null; end if;  -- the first card sets it
  v_same := case when nullif(p_fingerprint, '') is not null and (r ->> 'fingerprint') is not null then p_fingerprint = r ->> 'fingerprint'
                 else p_last4 is not distinct from (r ->> 'last4') end;
  if v_same then return null; end if;
  return format('This rental''s coverage is the renter''s credit card: the whole rental is paid on that same card (%s ending %s). This card ends %s. Use the same card, or an Admin may allow another card with the reason.',
                initcap(coalesce(r ->> 'brand', 'card')), coalesce(r ->> 'last4', '????'), coalesce(p_last4, '????'));
end $$;

-- p: booking, reason (10 characters or more); an Admin
create function app.card_coverage_override(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
begin
  perform app.assert_admin(p_by);
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if coalesce(b.coverage_option, 0) <> 2 then raise exception 'Booking % does not use credit card coverage', b.booking_number using errcode = '23514'; end if;
  if v_reason is null or length(v_reason) < 10 then raise exception 'Give the reason (10 characters or more)' using errcode = '22023'; end if;
  insert into booking_card_overrides (booking_id, reason, created_by) values (b.id, v_reason, p_by)
  on conflict (booking_id) do update set reason = excluded.reason, created_by = excluded.created_by, created_at = now();
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, b.current_offer_version,
    'Another card or payment method allowed for the rental: ' || v_reason, p_by, 'staff', jsonb_build_object('card_override', true));
  return jsonb_build_object('ok', true);
end $$;

-- ================================================================ the checks
-- 1. a payment recorded another way (e-Transfer, cash...) for the rental or the fees
alter function app.record_booking_payment(uuid, jsonb) rename to record_booking_payment_pre0203;
create function app.record_booking_payment(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_b uuid := (select id from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) limit 1);
  r jsonb;
begin
  if v_b is not null and coalesce(nullif(p ->> 'covers', ''), 'rental') in ('rental', 'fees', 'both') then
    r := app.card_coverage_ref(v_b);
    if (r ->> 'required')::boolean and not coalesce((r ->> 'overridden')::boolean, false) then
      raise exception 'This rental''s coverage is the renter''s credit card: the whole rental is paid on that card%, not by %. Take it on the card, or an Admin may allow another way with the reason.',
        coalesce(format(' (%s ending %s)', initcap(coalesce(r ->> 'brand', 'card')), r ->> 'last4'), ''), app.payment_method_label(coalesce(nullif(p ->> 'method', ''), 'e_transfer'))
        using errcode = '23514';
    end if;
  end if;
  return app.record_booking_payment_pre0203(p_by, p);
end $$;
select pg_temp.copy_grants('app.record_booking_payment(uuid, jsonb)'::regprocedure, 'app.record_booking_payment_pre0203(uuid, jsonb)'::regprocedure);

-- 2. a card recorded by hand: the last 4 digits, and the staff member confirms it is the same card (same_card)
alter function app.record_card_payment(uuid, jsonb) rename to record_card_payment_pre0203;
create function app.record_card_payment(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_b uuid := (select id from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) limit 1);
  r jsonb;
  v_refuse text;
begin
  if v_b is not null and coalesce(nullif(p ->> 'covers', ''), 'rental') in ('rental', 'fees', 'both') and coalesce(current_setting('app.payment_parts', true), '') = '' then
    r := app.card_coverage_ref(v_b);
    if (r ->> 'required')::boolean and not coalesce((r ->> 'overridden')::boolean, false) then
      v_refuse := app.card_coverage_same_card(v_b, p #>> '{verified,fingerprint}', nullif(btrim(coalesce(p ->> 'last4', '')), ''));
      if v_refuse is not null then raise exception '%', v_refuse using errcode = '23514'; end if;
      if not coalesce((p ->> 'same_card')::boolean, false) then
        raise exception 'This rental''s coverage is the renter''s credit card: confirm this is the same card%', coalesce(format(' (%s ending %s)', initcap(coalesce(r ->> 'brand', 'card')), r ->> 'last4'), '')
          using errcode = '22023';
      end if;
    end if;
  end if;
  return app.record_card_payment_pre0203(p_by, p);
end $$;
select pg_temp.copy_grants('app.record_card_payment(uuid, jsonb)'::regprocedure, 'app.record_card_payment_pre0203(uuid, jsonb)'::regprocedure);

-- 3. a card request (the pay page or the reader): the card read, before the reader's charge is captured
create or replace function public.server_payreq_card_check(p_id uuid, p_card jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  q payment_requests;
  v_refuse text;
begin
  select * into q from payment_requests where id = p_id;
  if q.id is null or q.kind <> 'charge' or q.covers not in ('rental', 'fees', 'balance') then return jsonb_build_object('ok', true); end if;
  v_refuse := app.card_coverage_same_card(q.booking_id, p_card ->> 'fingerprint', p_card ->> 'last4');
  return case when v_refuse is null then jsonb_build_object('ok', true) else jsonb_build_object('ok', false, 'reason', v_refuse) end;
end $$;

alter function public.server_payreq_settle(uuid, jsonb) rename to server_payreq_settle_pre0203;
create function public.server_payreq_settle(p_id uuid, p_intent jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  q payment_requests;
  c jsonb;
begin
  select * into q from payment_requests where id = p_id;
  if q.id is not null and q.status = 'open' and q.kind = 'charge' and p_intent ->> 'status' = 'succeeded' then
    c := public.server_payreq_card_check(p_id, coalesce(p_intent -> 'card', '{}'::jsonb));
    if not (c ->> 'ok')::boolean then
      update payment_requests set status = 'failed', last_error = left(c ->> 'reason', 300), completed_at = now() where id = q.id and status = 'open';
      insert into audit_log (action, entity_table, entity_id, after)
      values ('card_coverage_other_card', 'payment_requests', q.id::text, jsonb_build_object('intent_id', p_intent ->> 'id', 'last4', p_intent #>> '{card,last4}'));
      -- the website gives the money back at once (it was captured on the pay page)
      return jsonb_build_object('ok', false, 'reason', c ->> 'reason', 'refund', true);
    end if;
  end if;
  return public.server_payreq_settle_pre0203(p_id, p_intent);
end $$;
select pg_temp.copy_grants('public.server_payreq_settle(uuid, jsonb)'::regprocedure, 'public.server_payreq_settle_pre0203(uuid, jsonb)'::regprocedure);

-- the booking's money shows the rule (0129 booking_money)
alter function app.booking_money(uuid, jsonb) rename to booking_money_pre0203;
create function app.booking_money(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := app.booking_money_pre0203(p_by, p);
begin
  if v ? 'booking_id' then
    v := v || jsonb_build_object('card_rule', app.card_coverage_ref((v ->> 'booking_id')::uuid) - 'fingerprint' - 'payment_method_id',
                                 'readers', app.terminal_readers(p_by), 'is_admin', app.user_is_admin(p_by));
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.booking_money(uuid, jsonb)'::regprocedure, 'app.booking_money_pre0203(uuid, jsonb)'::regprocedure);

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0203;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'ops_do' and p_name = 'card_coverage_override' then
    perform app.door_begin(p_user, p_aal);
    return app.card_coverage_override(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre0203(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0203(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['card_coverage_ref', 'card_coverage_same_card', 'card_coverage_override', 'record_booking_payment_pre0203',
              'record_card_payment_pre0203', 'booking_money_pre0203', 'door_pre0203']))
        or (n.nspname = 'public' and p.proname = any (array['server_payreq_card_check', 'server_payreq_settle_pre0203']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
