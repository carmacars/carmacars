-- 2911 (release 48): a returning renter signs in one tap, and what they told us once is not asked again.
--
-- The owner's report (Nov 14): "Signing for renters needs to be easier and their info needs to be saved whenever it's
-- repetitive."
-- 1. The renter's drawn signature and initials are saved on their profile when they sign (renters.saved_signature_path,
--    saved_initials_path, kept privately in the agreements store). Next time the signing page offers "Initial all with
--    your saved initials" and "Sign with your saved signature": one tap each (public.server_esign_use_saved). Only for the signed-in renter's own remote session, never
--    on a staff member's device and never for an additional driver.
-- 2. public.renter_prefill: what the renter already gave us, for the blanks of the agreement (date of birth, home
--    address, mobile, email, licence, the insurer and policy or the card of their last booking, the emergency contact,
--    the drivers they added before, their initials and whether a saved signature is on file). Only the renter's own
--    data, checked against the signed-in user, read on the server: never in a link.
-- 3. renter_agreement_fill already saves the profile's blanks; the coverage of a booking now prefills the next one.
set local check_function_bodies = off;

alter table renters add column if not exists saved_signature_path text,
                    add column if not exists saved_signature_at timestamptz,
                    add column if not exists saved_initials_path text;
comment on column renters.saved_signature_path is 'The renter''s last drawn signature (2911), a private key of the agreements store; reused with one tap.';
comment on column renters.saved_initials_path is 'The renter''s last drawn initials (2911), a private key of the agreements store; reused with one tap.';

-- Initials of a name: the first letter of the first and the last word ("Jose Maria Garcia-Lopez" -> "JL").
create or replace function app.person_initials(p text) returns text
language sql immutable as $$
  select upper(case when cardinality(t) = 0 then '' when cardinality(t) = 1 then left(t[1], 1) else left(t[1], 1) || left(t[cardinality(t)], 1) end)
    from (select app.person_name_tokens(p) t) x
$$;

-- A renter's signing session that signs saves its drawn signature and initials on their profile.
create or replace function app.save_renter_signature() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_ini text := (select x.value ->> 'path' from jsonb_each(new.initials) x where coalesce(x.value ->> 'path', '') ~ '^esign/[0-9a-f-]{36}/' order by x.key limit 1);
  v_sig text := case when new.signature_method = 'drawn' and coalesce(new.signature_path, '') ~ '^esign/[0-9a-f-]{36}/signature-[0-9a-f-]{36}\.png$' then new.signature_path end;
begin
  if new.signed_at is not null and old.signed_at is null and new.signer_role = 'renter' and new.context in ('rental_agreement', 'amendment')
     and new.booking_id is not null and (v_sig is not null or v_ini is not null) then
    update renters r set saved_signature_path = coalesce(v_sig, r.saved_signature_path), saved_initials_path = coalesce(v_ini, r.saved_initials_path),
           saved_signature_at = now()
      from bookings b where b.id = new.booking_id and r.id = b.renter_id;
  end if;
  return new;
end $$;
drop trigger if exists esign_sessions_save_renter on esign_sessions;
create trigger esign_sessions_save_renter after update of signed_at on esign_sessions for each row execute function app.save_renter_signature();

-- The saved signature this session may use: the booking renter's, for their own remote session.
create or replace function app.esign_saved_path(s esign_sessions, p_part text default 'signature') returns text
language sql stable security definer set search_path = public, app as $$
  select case p_part when 'initials' then r.saved_initials_path else r.saved_signature_path end from bookings b join renters r on r.id = b.renter_id
   where s.id is not null and b.id = s.booking_id and s.method = 'remote' and s.signer_role = 'renter'
     and s.context in ('rental_agreement', 'amendment')
$$;

-- What the signing page offers: the saved signature (yes or no, never the key) and the initials.
create or replace function public.server_esign_saved(p_session uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s esign_sessions;
begin
  select * into s from esign_sessions where id = p_session;
  if s.id is null then raise exception 'This signing has ended: reload the page' using errcode = '23514'; end if;
  return jsonb_build_object('saved_signature', app.esign_saved_path(s) is not null, 'saved_initials', app.esign_saved_path(s, 'initials') is not null,
                            'initials', nullif(app.person_initials(s.signer_name), ''));
end $$;

-- One tap: the saved initials go on every key term ('initials'), or the saved signature becomes the session's drawn
-- signature ('signature'). Each is recorded as its steps, marked saved.
create or replace function public.server_esign_use_saved(p_session uuid, p_part text, p_ip text default null, p_user_agent text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s esign_sessions;
  v_path text;
  k text;
begin
  select * into s from esign_sessions where id = p_session for update;
  if s.id is null or s.signed_at is not null then raise exception 'This signing has ended: reload the page' using errcode = '23514'; end if;
  if p_part not in ('initials', 'signature') then raise exception 'Unknown step' using errcode = '22023'; end if;
  v_path := app.esign_saved_path(s, p_part);
  if v_path is null then raise exception 'No saved % yet: draw it in the box', case p_part when 'initials' then 'initials' else 'signature' end using errcode = 'P0002'; end if;
  if s.otp_verified_at is null and coalesce((app.settings()).esign_code_required, false) then
    raise exception 'Confirm the code first' using errcode = '23514';
  end if;
  if p_part = 'initials' then
    if s.viewed_at is null then raise exception 'Read the agreement first' using errcode = '23514'; end if;
    for k in select unnest(s.required_initials) loop
      update esign_sessions set initials = initials || jsonb_build_object(k, jsonb_build_object('at', now(), 'path', v_path, 'saved', true)), updated_at = now() where id = s.id;
      insert into esign_events (session_id, kind, detail, ip_address, user_agent)
      values (s.id, 'initial', jsonb_build_object('code', k, 'path', v_path, 'saved', true), nullif(p_ip, '')::inet, p_user_agent);
    end loop;
  else
    update esign_sessions set signature_method = 'drawn', signature_path = v_path, typed_fallback = false, updated_at = now() where id = s.id;
    insert into esign_events (session_id, kind, detail, ip_address, user_agent)
    values (s.id, 'signature', jsonb_build_object('method', 'drawn', 'path', v_path, 'saved', true), nullif(p_ip, '')::inet, p_user_agent);
  end if;
  update esign_sessions set ip_address = coalesce(nullif(p_ip, '')::inet, ip_address), user_agent = coalesce(p_user_agent, user_agent) where id = s.id;
  -- the signature's key goes back to the renter's own page, as a drawing's does: the signing call sends it
  return app.esign_view(s.id) || case when p_part = 'signature' then jsonb_build_object('path', v_path) else '{}'::jsonb end;
end $$;

-- A drawing recorded with the session's saved signature passes the check of 2910 (it is the session's signature_path).

-- What the renter already gave us, for this booking's blanks (their own data only).
create or replace function public.renter_prefill(p_booking uuid, p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r renters;
  d drivers;
  c coverage_proofs;
begin
  perform app.assert_booking_renter(p_booking, p_by);
  select x.* into r from bookings b join renters x on x.id = b.renter_id where b.id = p_booking;
  select * into d from drivers where renter_id = r.id and is_account_holder order by updated_at desc nulls last limit 1;
  select cp.* into c from coverage_proofs cp join bookings b2 on b2.id = cp.booking_id
   where b2.renter_id = r.id and cp.status <> 'rejected'
     and (nullif(btrim(coalesce(cp.insurer_name, '')), '') is not null or nullif(btrim(coalesce(cp.card_issuer, '')), '') is not null)
   order by (cp.booking_id = p_booking) desc, cp.created_at desc limit 1;
  return jsonb_strip_nulls(jsonb_build_object(
    'legal_name', r.legal_name, 'email', r.email, 'mobile', r.mobile, 'date_of_birth', coalesce(r.date_of_birth, d.date_of_birth),
    'address_line1', coalesce(r.address_line1, d.address_line1), 'address_line2', coalesce(r.address_line2, d.address_line2),
    'city', coalesce(r.city, d.city), 'province', coalesce(r.province, d.province), 'postal_code', coalesce(r.postal_code, d.postal_code), 'country', r.country,
    'licence_number', d.licence_number, 'licence_class', d.licence_class, 'licence_issuer', d.licence_issuer,
    'licence_expiry', case when d.licence_expiry >= current_date then d.licence_expiry end,
    'insurer_name', c.insurer_name, 'policy_number', c.policy_number, 'policy_expiry', case when c.policy_expiry >= current_date then c.policy_expiry end,
    'card_issuer', c.card_issuer, 'card_last4', c.card_last4,
    'secondary_contact', r.secondary_contact,
    'drivers_before', (select jsonb_agg(jsonb_build_object('id', x.id, 'full_name', x.full_name) order by x.full_name) from drivers x where x.renter_id = r.id and not x.is_account_holder),
    'initials', nullif(app.person_initials(r.legal_name), ''),
    'saved_signature', r.saved_signature_path is not null));
end $$;

revoke all on function public.renter_prefill(uuid, uuid), public.server_esign_saved(uuid), public.server_esign_use_saved(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.renter_prefill(uuid, uuid), public.server_esign_saved(uuid), public.server_esign_use_saved(uuid, text, text, text) to service_role;
revoke all on function app.save_renter_signature(), app.esign_saved_path(esign_sessions, text) from public;
grant execute on function app.person_initials(text) to authenticated, service_role;
