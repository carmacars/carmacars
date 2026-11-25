-- 3871: stripe_find_payments and stripe_booking name the payer (Release 50, dispute evidence). Read only.
-- SCHEMA_MARKER 3871. No applied migration is edited.
-- The web layer reads from Stripe the receipt email, the billing name, email and phone, the Customer's email and name and the
-- card's fingerprint (never its number) (src/features/api-access/stripe-inspect.ts), then asks here which renters they match
-- (an email or phone of the renter or their sign-in, or a card on file with that fingerprint) and which of their bookings
-- fall around the payment, with what is still open on each.
set local check_function_bodies = off;

-- p: [{id, at (epoch seconds or ISO), emails: [...], phones: [...], fingerprint}] -> {<id>: {renters: [...], bookings: [...]}}
create function app.stripe_payer_match(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  x jsonb;
  v_at timestamptz;
  v_emails text[];
  v_phones text[];
  v_fp text;
  v_renters jsonb;
  v_bookings jsonb;
  out jsonb := '{}'::jsonb;
  b record;
  v_open jsonb;
begin
  for x in select e from jsonb_array_elements(case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end) e limit 500 loop
    v_at := case when jsonb_typeof(x -> 'at') = 'number' then to_timestamp((x ->> 'at')::double precision) else nullif(x ->> 'at', '')::timestamptz end;
    v_emails := array(select distinct lower(btrim(e)) from jsonb_array_elements_text(coalesce(x -> 'emails', '[]'::jsonb)) e where e like '%@%');
    v_phones := array(select distinct app.phone_e164(e) from jsonb_array_elements_text(coalesce(x -> 'phones', '[]'::jsonb)) e where app.phone_e164(e) is not null);
    v_fp := nullif(btrim(coalesce(x ->> 'fingerprint', '')), '');
    with m as (
      select r.id, array_remove(array[
          case when lower(r.email) = any (v_emails) or lower(u.email) = any (v_emails) then 'email' end,
          case when app.phone_e164(r.mobile) = any (v_phones) or app.phone_e164(u.phone) = any (v_phones) then 'phone' end,
          case when v_fp is not null and exists (select 1 from payment_methods pm join payment_method_secrets s on s.payment_method_id = pm.id
                                                  where pm.renter_id = r.id and s.fingerprint = v_fp) then 'card_fingerprint' end], null) why
        from renters r left join users u on u.id = r.user_id
       where r.merged_into is null
         and (lower(r.email) = any (v_emails) or lower(u.email) = any (v_emails)
              or app.phone_e164(r.mobile) = any (v_phones) or app.phone_e164(u.phone) = any (v_phones)
              or (v_fp is not null and exists (select 1 from payment_methods pm join payment_method_secrets s on s.payment_method_id = pm.id
                                                where pm.renter_id = r.id and s.fingerprint = v_fp)))
       limit 10)
    select coalesce(jsonb_agg(jsonb_build_object('renter_id', r.id, 'name', r.legal_name, 'email', r.email, 'matched_by', to_jsonb(m.why)) order by r.created_at), '[]'::jsonb)
      into v_renters from m join renters r on r.id = m.id;
    v_bookings := '[]'::jsonb;
    for b in select bk.id, bk.booking_number, bk.status, bk.pickup_at, bk.return_at, bk.renter_id from bookings bk
              where bk.renter_id in (select (j ->> 'renter_id')::uuid from jsonb_array_elements(v_renters) j)
                and (v_at is null or v_at between coalesce(bk.booked_at, bk.created_at) - interval '3 days' and coalesce(bk.return_at, bk.pickup_at) + interval '30 days'
                     or bk.status::text in ('pending_payment', 'offered', 'tentative'))
              order by abs(extract(epoch from coalesce(bk.pickup_at, bk.created_at) - coalesce(v_at, now()))) limit 10 loop
      begin
        v_open := jsonb_build_object('rental_cents', app.booking_part_open(b.id, 'rental'), 'deposit_cents', app.booking_part_open(b.id, 'deposit'),
                                     'fees_cents', app.booking_part_open(b.id, 'fees'), 'balance_cents', app.booking_balance_open(b.id));
      exception when others then v_open := null;
      end;
      v_bookings := v_bookings || jsonb_build_object('booking_number', b.booking_number, 'renter_id', b.renter_id, 'status', b.status, 'pickup_at', b.pickup_at, 'return_at', b.return_at, 'open', v_open);
    end loop;
    out := out || jsonb_build_object(x ->> 'id', jsonb_build_object('renters', v_renters, 'bookings', v_bookings,
             'matched', jsonb_array_length(v_renters) > 0));
  end loop;
  return out;
end $$;
comment on function app.stripe_payer_match(jsonb) is 'r50 (3871): the renters a Stripe payer''s email, phone or card fingerprint match, and their bookings around the payment with what is open, for stripe_find_payments and stripe_booking (matched_renter).';

create function public.server_stripe_payer_match(p jsonb) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$ select app.stripe_payer_match(p) $$;

revoke all on function app.stripe_payer_match(jsonb), public.server_stripe_payer_match(jsonb) from public, anon, authenticated;
grant execute on function app.stripe_payer_match(jsonb), public.server_stripe_payer_match(jsonb) to service_role;
