-- 2610_r42_fixes.sql (release 42)
-- 1. The owner's new booking email when a booking that was left out starts counting.
--    2480 leaves a booking out of its car owner's revenue and visibility when it is an insurer rental that does not block the
--    calendar, is an insurance replacement hidden from the owner, or has "Counts toward the owner's revenue" off, and the 0156
--    trigger drops its owner booking notices ("not shown to the owner"). When staff later switch it so it counts (Blocks the
--    calendar turned on, shown to the owner, billed to the renter, "Counts toward the owner's revenue" on again), the owner has
--    never been told. app.booking_counts_for_owner flipping false to true now emits owner_new_booking once
--    (dedupe key owner_new_booking:<booking>:counted), unless the owner already got that notice (an earlier one that was not
--    dropped) or the owner still sees only "unavailable" for it. The one trigger covers every place that changes those fields.
-- 2. The card that covers a rental, on the renter's pay page. app.record_booking_payment (wrapped, _pre2610) refuses a card of
--    another network than the coverage card (card_network_mismatch, "Nothing was charged"), before the booking is confirmed;
--    public.server_coverage_card_network gives the pay page the network to name and to check in the browser.
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

-- ================================================================ 1. the owner's new booking notice
create function app.owner_counts_flip_notice() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.booking_type::text = 'owner' or new.owner_id is null
     or new.status::text not in ('confirmed', 'on_rent', 'returned', 'closed') then
    return null;
  end if;
  if app.booking_counts_for_owner(old) or not app.booking_counts_for_owner(new) then return null; end if;
  -- the owner still sees nothing of it (hidden with no owner revenue): the notice would be dropped, and kept for a later flip
  if app.booking_owner_view(new) = 'unavailable' then return null; end if;
  -- the owner already had (or has waiting) the new booking notice
  if exists (select 1 from app_events e where e.code = 'owner_new_booking' and e.entity = 'booking' and e.entity_id = new.id
              and coalesce(e.process_note, '') not like 'not shown to the owner%') then
    return null;
  end if;
  perform app.ntf_emit('owner_new_booking', 'booking', new.id, 'counted',
                       jsonb_build_object('booking_id', new.id, 'owner_id', new.owner_id));
  perform app.log_booking_event(new.id, 'adjusted', new.status::text, new.status::text, null,
                                'The booking now counts toward the owner''s revenue: the owner is sent the new booking notice', null, 'system');
  return null;
end $$;
comment on function app.owner_counts_flip_notice() is 'Release 42 (2610): a booking left out of the owner''s revenue (2480) that starts counting sends the owner its new booking notice once.';
create trigger bookings_owner_counts_flip after update of blocks_calendar, owner_visibility, owner_revenue_excluded, bill_to, status on bookings
  for each row when (old.* is distinct from new.*) execute function app.owner_counts_flip_notice();

-- ================================================================ 2. the card that covers the rental
create function app.card_brand_key(p_brand text) returns text
language sql immutable as $$
  select case when nullif(btrim(coalesce(p_brand, '')), '') is null then null
              else case regexp_replace(lower(p_brand), '[^a-z]', '', 'g')
                     when 'americanexpress' then 'amex' when 'amex' then 'amex'
                     when 'mastercard' then 'mastercard' when 'master' then 'mastercard'
                     when 'dinersclub' then 'diners' when 'diners' then 'diners'
                     when 'unionpay' then 'unionpay' when 'chinaunionpay' then 'unionpay'
                     else regexp_replace(lower(p_brand), '[^a-z]', '', 'g') end end
$$;

-- the network of the card the rental must be paid on (null brand: not known yet, nothing to check)
create function public.server_coverage_card_network(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r jsonb := app.card_coverage_ref(p_booking);
  v_key text := app.card_brand_key(r ->> 'brand');
begin
  if not coalesce((r ->> 'required')::boolean, false) or coalesce((r ->> 'overridden')::boolean, false) or v_key is null then
    return jsonb_build_object('required', false);
  end if;
  return jsonb_build_object('required', true, 'brand', v_key, 'label', case v_key when 'amex' then 'American Express' when 'mastercard' then 'Mastercard'
                              when 'visa' then 'Visa' when 'diners' then 'Diners Club' when 'unionpay' then 'UnionPay' when 'jcb' then 'JCB'
                              else initcap(v_key) end);
end $$;

alter function app.record_booking_payment(uuid, jsonb, bigint, integer, jsonb, text, uuid) rename to record_booking_payment_pre2610;
create function app.record_booking_payment(p_booking uuid, p_processor jsonb, p_amount_cents bigint, p_offer_version integer,
                                           p_card jsonb default null, p_event_id text default null, p_by uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_need jsonb;
  v_got text := app.card_brand_key(p_card ->> 'brand');
begin
  if v_got is not null then
    v_need := public.server_coverage_card_network(p_booking);
    if coalesce((v_need ->> 'required')::boolean, false) and (v_need ->> 'brand') is distinct from v_got then
      return app.refuse_confirmation(p_booking, 'payment', 'card_network_mismatch',
        format('Pay with the card that covers this rental (%s). The card you used is a %s card, so the booking was not confirmed. Nothing was charged.',
               v_need ->> 'label', case v_got when 'amex' then 'American Express' when 'mastercard' then 'Mastercard' else initcap(v_got) end),
        jsonb_build_object('coverage_network', v_need ->> 'brand', 'card_network', v_got));
    end if;
  end if;
  return app.record_booking_payment_pre2610(p_booking, p_processor, p_amount_cents, p_offer_version, p_card, p_event_id, p_by);
end $$;
select pg_temp.copy_grants('app.record_booking_payment(uuid, jsonb, bigint, integer, jsonb, text, uuid)'::regprocedure,
                           'app.record_booking_payment_pre2610(uuid, jsonb, bigint, integer, jsonb, text, uuid)'::regprocedure);

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['owner_counts_flip_notice', 'card_brand_key', 'record_booking_payment_pre2610']))
        or (n.nspname = 'public' and p.proname = 'server_coverage_card_network')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
