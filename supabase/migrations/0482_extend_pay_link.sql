-- 0482: an approved extension paid by a pay link when the booking has no card on file, or the card on file was
-- declined (docs/changes/2026-11-07-extend-offers.md). The renter opens Stripe's own form on /pay/<token> from the
-- Extend page; paying confirms the extension exactly as a charge of the card on file does (app.confirm_extension_payment:
-- the return time moves, the reminders follow it). A payment that can no longer confirm it (the extension lapsed, the
-- car was taken) is refunded at once. SCHEMA_MARKER 0483.
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

alter table payment_requests add column if not exists extension_id uuid references booking_extensions(id);
alter table payment_requests drop constraint payment_requests_covers_check;
alter table payment_requests add constraint payment_requests_covers_check
  check (covers in ('rental', 'deposit', 'fees', 'later', 'card', 'balance', 'extension'));
alter table payment_requests add constraint payment_requests_extension_check
  check ((covers = 'extension') = (extension_id is not null) and (covers <> 'extension' or kind = 'charge'));
comment on column payment_requests.extension_id is 'The approved extension a renter pays by this link (0482).';

-- the renter's link for their approved extension: one open link at a time, for exactly its price
create or replace function public.renter_extension_payreq(p_extension uuid, p_by uuid, p_token_sha256 text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  e booking_extensions;
  b bookings;
  v_id uuid;
begin
  select * into e from booking_extensions where id = p_extension;
  if e.id is null then raise exception 'Extension not found' using errcode = 'P0002'; end if;
  perform app.assert_booking_renter(e.booking_id, p_by);
  select * into b from bookings where id = e.booking_id;
  if e.status <> 'approved' then raise exception 'This extension is not waiting for payment.' using errcode = '23514'; end if;
  if b.status::text not in ('confirmed', 'on_rent') or b.return_at <> e.previous_return_at then
    raise exception 'This extension can no longer be paid.' using errcode = '23514';
  end if;
  if coalesce(e.total_cents, 0) <= 0 then raise exception 'Nothing to pay for this extension.' using errcode = '23514'; end if;
  if p_token_sha256 is null or p_token_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'The link token is missing' using errcode = '22023'; end if;
  update payment_requests set status = 'cancelled', last_error = coalesce(last_error, 'Replaced by a new link')
   where extension_id = e.id and status = 'open';
  insert into payment_requests (booking_id, renter_id, kind, covers, extension_id, amount_cents, reason, token_sha256, channel, expires_at, created_by)
  values (b.id, b.renter_id, 'charge', 'extension', e.id, e.total_cents, 'the extension of your booking to ' || app.fmt_date(e.new_return_at) || ' ' || app.fmt_time(e.new_return_at),
          p_token_sha256, 'link', least(now() + interval '2 hours', e.new_return_at), p_by)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'kind', 'charge', 'covers', 'extension', 'amount_cents', e.total_cents, 'booking_id', b.id, 'booking_number', b.booking_number,
    'renter', (select jsonb_build_object('id', r.id, 'legal_name', r.legal_name, 'email', coalesce(r.email, u.email), 'mobile', r.mobile,
                 'customer_id', (select sc.processor_customer_id from payment_methods pm join payment_method_secrets sc on sc.payment_method_id = pm.id
                                  where pm.renter_id = r.id and sc.processor_customer_id is not null order by pm.created_at desc limit 1))
                 from renters r left join users u on u.id = r.user_id where r.id = b.renter_id));
end $$;
revoke all on function public.renter_extension_payreq(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.renter_extension_payreq(uuid, uuid, text) to service_role;

-- settling it: the card is saved like any link's, then the extension is confirmed; when it cannot be, the money goes
-- back (the caller refunds on "refund") and the link is closed with the reason
alter function public.server_payreq_settle(uuid, jsonb) rename to server_payreq_settle_pre0482;
create function public.server_payreq_settle(p_id uuid, p_intent jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  q payment_requests;
  b bookings;
  v_pm uuid;
  v_card jsonb := p_intent -> 'card';
  v_st text := p_intent ->> 'status';
  v jsonb;
begin
  select * into q from payment_requests where id = p_id for update;
  if q.id is null or q.covers <> 'extension' then return public.server_payreq_settle_pre0482(p_id, p_intent); end if;
  if q.status = 'paid' then return jsonb_build_object('ok', true, 'repeat', true, 'payment_id', q.payment_id); end if;
  if q.processor_intent_id is distinct from p_intent ->> 'id' then raise exception 'That payment is not this request''s' using errcode = '22023'; end if;
  if v_st <> 'succeeded' then
    update payment_requests set last_error = left(coalesce(p_intent ->> 'error', v_st), 300) where id = q.id;
    return jsonb_build_object('ok', false, 'reason', coalesce(p_intent ->> 'error', 'The payment did not go through'));
  end if;
  select * into b from bookings where id = q.booking_id;
  if v_card is not null and (p_intent ->> 'method_id') is not null then
    v_pm := app.save_card_on_file(b.renter_id, v_card || jsonb_build_object('cardholder_name', v_card ->> 'name', 'is_credit', (v_card ->> 'funding') = 'credit'),
              jsonb_build_object('processor', 'stripe', 'customer_id', p_intent ->> 'customer_id', 'method_id', p_intent ->> 'method_id', 'fingerprint', v_card ->> 'fingerprint'));
    if v_pm is not null then update bookings set card_on_file_id = v_pm where id = b.id; end if;
  end if;
  v := app.confirm_extension_payment(q.extension_id,
         jsonb_build_object('processor', 'stripe', 'payment_id', p_intent ->> 'id', 'charge_id', p_intent ->> 'charge_id'),
         (p_intent ->> 'amount')::bigint, now(), q.created_by);
  if coalesce((v ->> 'ok')::boolean, false) then
    update payment_requests set status = 'paid', completed_at = now(), payment_id = nullif(v ->> 'payment_id', '')::uuid where id = q.id;
    return jsonb_build_object('ok', true, 'payment_id', v ->> 'payment_id', 'extension_id', q.extension_id, 'return_at', v ->> 'return_at');
  end if;
  update payment_requests set status = 'failed', completed_at = now(), last_error = left(coalesce(v ->> 'message', 'The extension could not be confirmed'), 300) where id = q.id;
  return jsonb_build_object('ok', false, 'refund', true, 'reason', coalesce(v ->> 'message', 'The extension could not be confirmed. The payment is refunded.'));
end $$;
select pg_temp.copy_grants('public.server_payreq_settle(uuid, jsonb)'::regprocedure, 'public.server_payreq_settle_pre0482(uuid, jsonb)'::regprocedure);
