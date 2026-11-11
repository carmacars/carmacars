-- 1401_r35b_opcf27_pages.sql
-- Release 35 part B, task 2 (docs/changes/2026-11-11-r35-card-pick-opcf-fuel-delivery.md). The owner, November 11, 2026:
-- "Own insurance (OPCF 27): require upload of the policy (pink slip plus the OPCF 27 endorsement page) before the booking
-- can be confirmed; staff verify it (approve/reject with reason)."
--
-- 1. Each page of a proof says what it is (verification_uploads.page_kind): for OPCF 27 the pink slip (the liability
--    insurance card) or the OPCF 27 endorsement page; a card's benefit document for option 2. A new OPCF 27 page must say
--    which it is. Pages sent before this release have no kind and count as the whole policy.
-- 2. app.opcf27_missing(booking): what is still to send ("pink slip", "OPCF 27 endorsement"), empty when nothing is, when
--    the proof is confirmed, or when the booking is not on option 1.
-- 3. The booking is not confirmed without them: the payment facts carry coverage_missing and the payment is refused
--    while anything is missing (Program settings opcf27_before_payment, on by default), as the licence is (0130).
-- 4. Staff approve or reject the proof as before (app.review_coverage_proof: Reject needs the reason the renter sees);
--    Approve is refused until both pages are in.
-- No applied migration is edited.

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '1401: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. what each page is
alter table verification_uploads
  add column if not exists page_kind text check (page_kind is null or page_kind in ('pink_slip', 'endorsement', 'card_benefit'));
comment on column verification_uploads.page_kind is 'A proof of coverage page (1401): pink_slip (the liability insurance card) or endorsement (the OPCF 27 endorsement page) for option 1, card_benefit for option 2; null on pages sent before 1401 (the whole policy)';

alter table program_settings
  add column if not exists opcf27_before_payment boolean not null default true;
comment on column program_settings.opcf27_before_payment is 'On (the default): a booking on OPCF 27 (coverage option 1) is paid and confirmed only once the pink slip and the OPCF 27 endorsement page are uploaded (1401)';

create or replace function app.opcf27_page_label(p text) returns text
language sql immutable as $$
  select case p when 'pink_slip' then 'pink slip' when 'endorsement' then 'OPCF 27 endorsement' when 'card_benefit' then 'card benefit document' else 'policy document' end
$$;

alter function app.register_verification_upload(uuid, uuid, text, uuid, text, text, text, jsonb, text) rename to register_verification_upload_pre1401;
create function app.register_verification_upload(p_booking uuid, p_by uuid, p_kind text, p_driver uuid, p_storage_path text, p_sha256 text default null,
  p_mime_type text default null, p_details jsonb default null, p_storage_bucket text default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  v_option integer;
  v_page text := nullif(btrim(coalesce(p_details ->> 'page_kind', '')), '');
  v_id uuid;
begin
  if p_kind = 'coverage_proof' then
    v_option := coalesce(nullif(p_details ->> 'coverage_option', '')::integer, (select b.coverage_option from bookings b where b.id = p_booking));
    if v_option = 1 and (v_page is null or v_page not in ('pink_slip', 'endorsement')) then
      raise exception 'Say which page this is: the pink slip or the OPCF 27 endorsement page' using errcode = '22023';
    end if;
    if v_option = 2 then v_page := 'card_benefit'; end if;
  else
    v_page := null;
  end if;
  v_id := app.register_verification_upload_pre1401(p_booking, p_by, p_kind, p_driver, p_storage_path, p_sha256, p_mime_type, p_details, p_storage_bucket);
  if v_page is not null then
    update verification_uploads set page_kind = v_page where id = v_id;
    update documents d set title = case v_page when 'pink_slip' then 'Pink slip' when 'endorsement' then 'OPCF 27 endorsement' else d.title end
                                   || case when v_page in ('pink_slip', 'endorsement') then ', booking ' || (select b.booking_number from bookings b where b.id = p_booking) else '' end
      from verification_uploads u where u.id = v_id and d.id = u.document_id and v_page in ('pink_slip', 'endorsement');
  end if;
  return v_id;
end $$;

-- ================================================================ 2. what is still to send
create or replace function app.opcf27_missing(p_booking uuid) returns text[]
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  cp coverage_proofs;
  v_kinds text[];
begin
  select * into b from bookings where id = p_booking;
  if b.id is null or b.booking_type = 'owner' or b.coverage_option is distinct from 1 or b.coverage_confirmed_at is not null then return '{}'; end if;
  select * into cp from coverage_proofs where booking_id = p_booking and coverage_option = 1 and status in ('submitted', 'confirmed') order by created_at desc limit 1;
  if cp.status = 'confirmed' then return '{}'; end if;
  if cp.id is not null then
    select coalesce(array_agg(distinct coalesce(u.page_kind, 'legacy')), '{}') into v_kinds
      from verification_uploads u where u.coverage_proof_id = cp.id and u.status in ('submitted', 'approved');
  end if;
  v_kinds := coalesce(v_kinds, '{}');
  if 'legacy' = any (v_kinds) then return '{}'; end if;   -- a whole policy sent before 1401
  return array(select app.opcf27_page_label(k) from unnest(array['pink_slip', 'endorsement']) k where not k = any (v_kinds));
end $$;

-- ================================================================ 3. no payment (and so no confirmation) without them
create or replace function app.opcf27_gate(p_booking uuid) returns text[]
language sql stable security definer set search_path = public, app as $$
  select case when coalesce((app.settings()).opcf27_before_payment, true) then app.opcf27_missing(p_booking) else '{}'::text[] end
$$;

alter function public.server_booking_payment_facts(uuid) rename to server_booking_payment_facts_pre1401;
alter function public.server_booking_payment_facts_pre1401(uuid) set schema app;
create function public.server_booking_payment_facts(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  f jsonb := app.server_booking_payment_facts_pre1401(p_booking);
begin
  if f is null then return null; end if;
  return f || jsonb_build_object('coverage_missing', to_jsonb(app.opcf27_gate(p_booking)));
end $$;

-- ================================================================ 4. staff approve only with both pages
select pg_temp.patch_fn('app.review_coverage_proof(uuid, uuid, boolean, text, jsonb)'::regprocedure,
  $o$      if not exists (select 1 from verification_uploads u where u.coverage_proof_id = cp.id and u.status = 'submitted') then
        raise exception 'The renter has not sent the policy document yet' using errcode = '23514';
      end if;$o$,
  $n$      if not exists (select 1 from verification_uploads u where u.coverage_proof_id = cp.id and u.status = 'submitted') then
        raise exception 'The renter has not sent the policy document yet' using errcode = '23514';
      end if;
      if cardinality(app.opcf27_missing(b.id)) > 0 then
        raise exception 'Both pages are needed before approving: % still missing', array_to_string(app.opcf27_missing(b.id), ' and ') using errcode = '23514';
      end if;$n$);

-- the reads carry the page kinds and what is missing
alter function app.renter_coverage(uuid) rename to renter_coverage_pre1401;
create function app.renter_coverage(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.renter_coverage_pre1401(p_booking);
begin
  if x is null then return null; end if;
  return x || jsonb_build_object('opcf27_missing', to_jsonb(app.opcf27_missing(p_booking)), 'opcf27_before_payment', coalesce((app.settings()).opcf27_before_payment, true),
    'page_kinds', coalesce((select jsonb_object_agg(u.id, u.page_kind) from verification_uploads u
                             where u.coverage_proof_id = (x #>> '{proof,id}')::uuid and u.page_kind is not null), '{}'::jsonb));
end $$;

alter function app.coverage_review_facts(uuid) rename to coverage_review_facts_pre1401;
create function app.coverage_review_facts(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.coverage_review_facts_pre1401(p_booking);
begin
  if x is null then return null; end if;
  return x || jsonb_build_object('opcf27_missing', to_jsonb(app.opcf27_missing(p_booking)),
    'page_kinds', coalesce((select jsonb_object_agg(u.id, u.page_kind) from verification_uploads u
                             where u.coverage_proof_id = (x #>> '{proof,id}')::uuid and u.page_kind is not null), '{}'::jsonb));
end $$;

do $$
declare g text; f text; pre text;
begin
  foreach f in array array['app.renter_coverage(uuid)', 'app.coverage_review_facts(uuid)', 'public.server_booking_payment_facts(uuid)',
                           'app.register_verification_upload(uuid, uuid, text, uuid, text, text, text, jsonb, text)'] loop
    pre := case f when 'public.server_booking_payment_facts(uuid)' then 'app.server_booking_payment_facts_pre1401(uuid)'
                  when 'app.register_verification_upload(uuid, uuid, text, uuid, text, text, text, jsonb, text)' then 'app.register_verification_upload_pre1401(uuid, uuid, text, uuid, text, text, text, jsonb, text)'
                  else replace(f, '(uuid)', '_pre1401(uuid)') end;
    execute format('revoke all on function %s from public', f);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      execute format('revoke all on function %s from %I', f, g);
      if has_function_privilege(g, pre, 'execute') then execute format('grant execute on function %s to %I', f, g); end if;
    end loop;
  end loop;
  foreach f in array array['app.opcf27_missing(uuid)', 'app.opcf27_gate(uuid)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

-- staff uploading a renter's insurance from the booking say which page it is too (empty: the whole policy)
select pg_temp.patch_fn('app.staff_document_register(uuid, jsonb)'::regprocedure,
  $o$    insert into verification_uploads (booking_id, driver_id, kind, document_id, identity_verification_id, coverage_proof_id, uploaded_by)
    values (b.id, null, 'coverage_proof', v_doc, null, cp.id, p_by);$o$,
  $n$    if nullif(p ->> 'page_kind', '') is not null and p ->> 'page_kind' not in ('pink_slip', 'endorsement', 'card_benefit') then
      raise exception 'Say which page this is: the pink slip or the OPCF 27 endorsement page' using errcode = '22023';
    end if;
    insert into verification_uploads (booking_id, driver_id, kind, document_id, identity_verification_id, coverage_proof_id, uploaded_by, page_kind)
    values (b.id, null, 'coverage_proof', v_doc, null, cp.id, p_by, nullif(p ->> 'page_kind', ''));$n$);
