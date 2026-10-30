-- 0186: e-sign without the one-time code, initials that can be cleared, discounts on the rental charge only (the owner,
-- October 28). SCHEMA_MARKER 0186.
--   1. Discounts come off the rental charge only (the daily, weekend, weekly or monthly rate part), never the fees, the
--      add-ons, the Protection Plan, the young driver fee, delivery or the deposit. The audit found the non-refundable
--      discount (a percentage of the rental charge), promo and game codes (computed on the rental charge less the other
--      discounts) already did. The staff discount did not have a cap: a discount larger than the rental charge took the
--      rest off the fees in a quote, and a booking refused it with a database error. It is now capped at the rental
--      charge (less the non-refundable discount), in app.price_lines and on the booking itself (a trigger), where the
--      promo discount is also kept within what is left of the rental charge until the price is synced again.
--   2. Initials can be cleared: server_esign_step kind 'initial_clear' removes one key term's initials from the session
--      and records it in the audit trail; the signer initials it again. The signing page saves initials only when the
--      signer presses "Save initials".
--   3. The one-time code is optional: Program setting esign_code_required (off). Off, a signing session is ready without
--      the code (still read, initials, consents, drawn signature, with the time, IP address and device of each step in
--      the certificate, which says the identity was not confirmed by a one-time code). On, the code is required as
--      before (0154).
-- No applied migration is edited.

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0186: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. discounts on the rental charge only
-- app.price_lines: the staff discount is at most the rental charge left after the non-refundable discount (the promo
-- code was already computed on what is left, and is 0 when nothing is)
select pg_temp.patch_fn('app.price_lines(jsonb)'::regprocedure,
  $o$  v_staff := coalesce((p ->> 'staff_discount_cents')::bigint, 0);$o$,
  $n$  v_staff := least(greatest(coalesce((p ->> 'staff_discount_cents')::bigint, 0), 0), greatest(v_rental - v_discount, 0));   -- 0186: never more than the rental charge$n$);

-- the booking: the discounts kept within the rental charge (the staff discount capped; the promo discount lowered until
-- app.sync_booking_price prices it again on what is left). Runs after the column guards (its name sorts last).
create or replace function app.bookings_discounts_within_rental() returns trigger
language plpgsql set search_path = public, app as $$
begin
  new.staff_discount_cents := least(greatest(coalesce(new.staff_discount_cents, 0), 0), greatest(new.rental_charge_cents - new.discount_cents, 0));
  new.promo_discount_cents := least(greatest(coalesce(new.promo_discount_cents, 0), 0), greatest(new.rental_charge_cents - new.discount_cents - new.staff_discount_cents, 0));
  return new;
end $$;
revoke all on function app.bookings_discounts_within_rental() from public, anon, authenticated;
grant execute on function app.bookings_discounts_within_rental() to service_role;
drop trigger if exists bookings_zz_discounts_within_rental on bookings;
create trigger bookings_zz_discounts_within_rental before insert or update of rental_charge_cents, discount_cents, staff_discount_cents, promo_discount_cents on bookings
  for each row execute function app.bookings_discounts_within_rental();
comment on function app.bookings_discounts_within_rental() is 'Discounts come off the rental charge only (0186): the staff discount is capped at the rental charge less the non-refundable discount, the promo discount at what is left.';

-- ================================================================ 3. the setting
alter table program_settings add column if not exists esign_code_required boolean not null default false;
comment on column program_settings.esign_strict is 'Rental agreements, amendments and new versions are signed only after reading, the initials, the consents and a drawn signature (0154), and the one-time code when esign_code_required is on (0186).';
comment on column program_settings.esign_code_required is 'E-signing asks for a one-time code by text or email before the signer initials and signs (0186: off, the owner''s choice; the certificate then says the identity was not confirmed by a code).';

-- ================================================================ 2. the audit trail: initials cleared
alter table esign_events drop constraint if exists esign_events_kind_check;
alter table esign_events add constraint esign_events_kind_check check (kind in ('started', 'code_sent', 'code_failed', 'code_verified', 'viewed', 'document_opened',
  'initial', 'initial_clear', 'consent', 'geolocation', 'signature', 'signed'));

-- server_esign_step: the kind 'initial_clear'; the code first only when Program settings require it
select pg_temp.patch_fn('public.server_esign_step(uuid,text,jsonb,text,text)'::regprocedure,
  $o$if p_kind not in ('viewed', 'document_opened', 'initial', 'consent', 'geolocation', 'signature') then$o$,
  $n$if p_kind not in ('viewed', 'document_opened', 'initial', 'initial_clear', 'consent', 'geolocation', 'signature') then$n$);
select pg_temp.patch_fn('public.server_esign_step(uuid,text,jsonb,text,text)'::regprocedure,
  $o$if p_kind in ('initial', 'consent', 'signature') and s.otp_verified_at is null then$o$,
  $n$if p_kind in ('initial', 'initial_clear', 'consent', 'signature') and s.otp_verified_at is null and coalesce((app.settings()).esign_code_required, false) then$n$);
select pg_temp.patch_fn('public.server_esign_step(uuid,text,jsonb,text,text)'::regprocedure,
  $o$  elsif p_kind = 'consent' then$o$,
  $n$  elsif p_kind = 'initial_clear' then
    -- 0186: the signer clears a term's initials and initials it again (the session is not ready until they do)
    if not v_code = any (s.required_initials) then raise exception 'Unknown term to initial' using errcode = '22023'; end if;
    update esign_sessions set initials = initials - v_code, updated_at = now() where id = s.id;
    d := jsonb_build_object('code', v_code, 'had_initials', s.initials ? v_code);
  elsif p_kind = 'consent' then$n$);

-- ready: the code only when Program settings require it
create or replace function app.esign_is_ready(s esign_sessions) returns boolean
language sql stable security definer set search_path = public, app as $$
  select s.id is not null and s.signed_at is null and s.created_at > now() - interval '2 hours'
     and (s.otp_verified_at is not null or not coalesce((app.settings()).esign_code_required, false))
     and s.viewed_at is not null
     and (select bool_and(s.initials ? x) from unnest(s.required_initials) x) is not false
     and (select bool_and(s.consents ? x) from unnest(s.required_consents) x) is not false
     and s.signature_path is not null
     and (s.signature_method = 'drawn' or (s.signature_method = 'typed' and s.typed_fallback and coalesce((app.settings()).esign_typed_fallback, false)))
$$;

-- the page's view: whether the code is required
create or replace function app.esign_view(p_session uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', s.id, 'context', s.context, 'signer_name', s.signer_name, 'signer_role', s.signer_role, 'method', s.method,
           'channels', (select coalesce(jsonb_agg(c), '[]'::jsonb) from (
              select jsonb_build_object('channel', 'sms', 'to', app.esign_mask_phone(s.mobile)) c where s.mobile is not null
              union all select jsonb_build_object('channel', 'email', 'to', app.esign_mask_email(s.email)) where s.email is not null) q),
           'code_sent_to', case s.otp_channel when 'sms' then app.esign_mask_phone(s.otp_to) when 'email' then app.esign_mask_email(s.otp_to) end,
           'verified', s.otp_verified_at is not null, 'code_required', coalesce((app.settings()).esign_code_required, false), 'viewed', s.viewed_at is not null,
           'required_initials', to_jsonb(s.required_initials), 'required_consents', to_jsonb(s.required_consents),
           'initials', (select coalesce(jsonb_agg(k), '[]'::jsonb) from jsonb_object_keys(s.initials) k),
           'consents', (select coalesce(jsonb_agg(k), '[]'::jsonb) from jsonb_object_keys(s.consents) k),
           'signature', s.signature_method, 'typed_fallback_allowed', coalesce((app.settings()).esign_typed_fallback, false),
           'licence', case when s.driver_id is not null and s.booking_id is not null then app.licence_status(s.booking_id, s.driver_id) end,
           'signed', s.signed_at is not null, 'ready', app.esign_is_ready(s))
    from esign_sessions s where s.id = p_session
$$;

-- what a signing without a complete session is told: the code only when it is required
create or replace function app.esign_incomplete_message(p_terms text) returns text
language sql stable security definer set search_path = public, app as $$
  select case when coalesce((app.settings()).esign_code_required, false) then 'Confirm your identity with the code, ' else 'Read the agreement, ' end
         || format('initial %s, give the consents and draw your signature before signing', p_terms)
$$;
revoke all on function app.esign_incomplete_message(text) from public, anon, authenticated;
grant execute on function app.esign_incomplete_message(text) to service_role;

select pg_temp.patch_fn('app.record_signature(uuid,uuid,text,text,inet,text,text,text,jsonb)'::regprocedure,
  $o$raise exception 'Confirm your identity with the code, initial the key terms, give the consents and draw your signature before signing' using$o$,
  $n$raise exception '%', app.esign_incomplete_message('the key terms') using$n$);
select pg_temp.patch_fn('app.sign_booking_amendment(uuid,uuid,text,text,text,text,inet,text)'::regprocedure,
  $o$raise exception 'Confirm your identity with the code, initial the payment term, give the consents and draw your signature before signing' using$o$,
  $n$raise exception '%', app.esign_incomplete_message('the payment term') using$n$);
select pg_temp.patch_fn('public.server_agreement_version_sign(uuid,jsonb)'::regprocedure,
  $o$raise exception 'Confirm your identity with the code, initial the key terms, give the consents and draw your signature before signing' using$o$,
  $n$raise exception '%', app.esign_incomplete_message('the key terms') using$n$);
