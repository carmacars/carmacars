-- 2920 (release 48): what a booking still needs for its coverage, said once, and read the same way by the renter's
-- checklist, the staff "Approve all (n)" and the get-ready tracker.
--
-- The owner's report (Nov 14): a renter on OPCF 27 sent one page of his policy. Documents said "Approve all (1)" with
-- nothing to approve, and the renter's checklist said "Under review", so he did not know a page was still missing.
-- Root causes:
--   * the review counted the proof of coverage as waiting as soon as it was "submitted" (DocumentReview, the staff
--     Verify page), while app.review_coverage_proof refuses it until the pink slip AND the OPCF 27 endorsement page are
--     in (1401), the policy details are complete and the policy runs past the return. Approve all then approved nothing.
--   * the Protection Plan was counted on a booking not paid yet; app.confirm_protection_plan refuses it before the booking
--     is confirmed, so the count again showed one item Approve all could not approve.
--   * the renter's checklist (app.renter_still_needed, 1203) read the newest coverage upload of any proof ("submitted":
--     Under review) and never app.opcf27_missing, so a missing page read as Under review, with a link to the page top.
-- One rule now: app.coverage_state(booking) says whether the proof (or the Protection Plan) can be approved right now
-- and, when not, exactly what the renter still has to send (each with the page kind to upload). The staff reads
-- (coverage_review_facts: Documents, Verify), Approve all, the readiness (booking_readiness.coverage_needs) and the
-- renter's checklist and coverage section (renter_coverage) all read it. A licence or selfie item links straight to its
-- upload too. No applied migration is edited: functions are wrapped (_pre2920) or patched in place.
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

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '2920: the text to change was not found in %: %', p_sig, left(p_old, 160);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ the one rule
-- {option, confirmed, proof_waiting, plan_waiting, needs: [{code, label, page_kind}]}
--   proof_waiting: the current proof is submitted and app.review_coverage_proof would approve it now
--   plan_waiting: the Protection Plan can be confirmed now (app.confirm_protection_plan's own conditions)
--   needs: what the renter still has to send or do, in plain words; empty while it waits for us or once confirmed
create function app.coverage_state(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  cp coverage_proofs;
  v_needs jsonb := '[]'::jsonb;
  v_missing text[];
  v_pages boolean;
  v_check jsonb;
  v_return date;
  v_plan boolean := false;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return null; end if;
  if b.booking_type = 'owner' or b.coverage_option is null or b.coverage_confirmed_at is not null then
    return jsonb_build_object('option', b.coverage_option, 'confirmed', b.coverage_confirmed_at is not null, 'proof_waiting', false, 'plan_waiting', false, 'needs', '[]'::jsonb);
  end if;
  if b.coverage_option = 3 then
    v_plan := b.status = 'confirmed'
      and exists (select 1 from booking_line_items li where li.booking_id = b.id and li.charge_type = 'coverage_sold' and li.voided_at is null);
    return jsonb_build_object('option', 3, 'confirmed', false, 'proof_waiting', false, 'plan_waiting', v_plan, 'needs', '[]'::jsonb);
  end if;
  if b.coverage_option not in (1, 2) then
    return jsonb_build_object('option', b.coverage_option, 'confirmed', false, 'proof_waiting', false, 'plan_waiting', false, 'needs', '[]'::jsonb);
  end if;
  cp := app.current_coverage_proof(b.id);
  v_return := app.local_date(b.return_at);
  if b.coverage_option = 1 then
    if cp.id is null or cp.status <> 'submitted' then
      v_missing := array['pink_slip', 'endorsement'];
    else
      if cp.insurer_name is null or cp.policy_number is null or cp.policy_expiry is null then
        v_needs := v_needs || jsonb_build_object('code', 'policy_details', 'label', 'your insurer, policy number and policy expiry date', 'page_kind', null);
      elsif cp.policy_expiry <= v_return then
        v_needs := v_needs || jsonb_build_object('code', 'policy_expiry', 'label', 'a policy that is still active after your return on ' || app.fmt_day(v_return), 'page_kind', null);
      end if;
      v_pages := exists (select 1 from verification_uploads u join documents d on d.id = u.document_id
                          where u.coverage_proof_id = cp.id and u.status = 'submitted' and d.purged_at is null);
      v_missing := case when v_pages then
          array(select k from unnest(array['pink_slip', 'endorsement']) k where app.opcf27_page_label(k) = any (app.opcf27_missing(b.id)))
        else array['pink_slip', 'endorsement'] end;
    end if;
    v_needs := v_needs || coalesce((select jsonb_agg(jsonb_build_object('code', k, 'page_kind', k,
                 'label', case k when 'pink_slip' then 'your pink slip (the insurance card for your own car)' else 'the OPCF 27 endorsement page of your policy' end) order by n)
               from unnest(v_missing) with ordinality x(k, n)), '[]'::jsonb);
  else
    if cp.id is null or cp.status <> 'submitted' or cp.renter_confirmed_at is null then
      v_needs := v_needs || jsonb_build_object('code', 'card_confirm', 'label', 'your confirmation that your credit card covers this rental', 'page_kind', null);
    else
      if cp.card_coverage_id is not null and app.card_product_check(b.id, cp.card_coverage_id) ->> 'result' = 'not_covered' then
        v_needs := v_needs || jsonb_build_object('code', 'card_other', 'label', 'another way to cover the car: your card does not cover this one', 'page_kind', null);
      end if;
      v_check := app.card_coverage_check(b.id);
      if not coalesce((v_check ->> 'eligible')::boolean, false) then
        v_needs := v_needs || jsonb_build_object('code', 'card_eligible', 'label', coalesce(v_check ->> 'message', 'a credit card in your name'), 'page_kind', null);
      elsif cp.payment_method_id is distinct from b.card_on_file_id then
        v_needs := v_needs || jsonb_build_object('code', 'card_confirm', 'label', 'your confirmation that your card on file covers this rental', 'page_kind', null);
      end if;
    end if;
  end if;
  return jsonb_build_object('option', b.coverage_option, 'confirmed', false, 'proof_id', cp.id, 'proof_status', cp.status,
    'proof_waiting', cp.id is not null and cp.status = 'submitted' and jsonb_array_length(v_needs) = 0,
    'plan_waiting', false, 'needs', v_needs);
end $$;
comment on function app.coverage_state(uuid) is 'r48 (2920): the one rule for a booking''s coverage: whether the proof or the Protection Plan can be approved now (proof_waiting, plan_waiting) and what the renter still has to send (needs, each with its page kind). The renter''s checklist, Approve all and its count, and the readiness read it.';

-- ================================================================ the staff reads and Approve all
alter function app.coverage_review_facts(uuid) rename to coverage_review_facts_pre2920;
create function app.coverage_review_facts(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.coverage_review_facts_pre2920(p_booking);
  s jsonb;
begin
  if x is null then return null; end if;
  s := app.coverage_state(p_booking);
  return x || jsonb_build_object('proof_waiting', coalesce((s ->> 'proof_waiting')::boolean, false), 'plan_waiting', coalesce((s ->> 'plan_waiting')::boolean, false),
                                 'needs', coalesce(s -> 'needs', '[]'::jsonb));
end $$;
select pg_temp.copy_grants('app.coverage_review_facts(uuid)'::regprocedure, 'app.coverage_review_facts_pre2920(uuid)'::regprocedure);

alter function app.renter_coverage(uuid) rename to renter_coverage_pre2920;
create function app.renter_coverage(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.renter_coverage_pre2920(p_booking);
begin
  if x is null then return null; end if;
  return x || jsonb_build_object('needs', coalesce(app.coverage_state(p_booking) -> 'needs', '[]'::jsonb));
end $$;
select pg_temp.copy_grants('app.renter_coverage(uuid)'::regprocedure, 'app.renter_coverage_pre2920(uuid)'::regprocedure);

-- Approve all approves the proof only when it can be approved (so its count and what it approves are the same)
select pg_temp.patch_fn('app.doc_review_approve_all_pre0169(uuid, jsonb)'::regprocedure,
  $o$  if cp.id is not null and cp.status = 'submitted' and cp.coverage_option in (1, 2) then$o$,
  $n$  if cp.id is not null and cp.status = 'submitted' and cp.coverage_option in (1, 2) and coalesce((app.coverage_state(b.id) ->> 'proof_waiting')::boolean, false) then$n$);

-- the review's own count: the uploads waiting (the one rule of 0780) plus the proof and the plan when they can be approved
alter function app.doc_review_read(uuid, jsonb) rename to doc_review_read_pre2920;
create function app.doc_review_read(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := app.doc_review_read_pre2920(p_by, p);
  v_b uuid;
  s jsonb;
begin
  if v is null or jsonb_typeof(v -> 'drivers') <> 'array' then return v; end if;
  v_b := (v ->> 'booking_id')::uuid;
  if jsonb_typeof(v -> 'coverage') = 'object' then
    s := app.coverage_state(v_b);
    return v || jsonb_build_object('waiting', (select count(*) from app.doc_review_pending(v_b))
      + case when coalesce((s ->> 'proof_waiting')::boolean, false) then 1 else 0 end + case when coalesce((s ->> 'plan_waiting')::boolean, false) then 1 else 0 end);
  end if;
  -- Sales: the licence images and the selfie only
  return v || jsonb_build_object('waiting', (select count(*) from app.doc_review_pending(v_b, array['licence_front', 'licence_back', 'selfie'])));
end $$;
select pg_temp.copy_grants('app.doc_review_read(uuid, jsonb)'::regprocedure, 'app.doc_review_read_pre2920(uuid, jsonb)'::regprocedure);

-- ================================================================ the readiness: what the coverage still needs
alter function app.booking_readiness(uuid) rename to booking_readiness_pre2920;
create function app.booking_readiness(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r jsonb := app.booking_readiness_pre2920(p_booking);
  s jsonb;
begin
  if r is null or coalesce((r ->> 'coverage_confirmed')::boolean, false) then return r; end if;
  s := app.coverage_state(p_booking);
  if s is null then return r; end if;
  return r || jsonb_build_object('coverage_needs', coalesce((select jsonb_agg(n ->> 'label') from jsonb_array_elements(s -> 'needs') n), '[]'::jsonb),
                                 'coverage_waiting', coalesce((s ->> 'proof_waiting')::boolean, false) or coalesce((s ->> 'plan_waiting')::boolean, false));
end $$;
select pg_temp.copy_grants('app.booking_readiness(uuid)'::regprocedure, 'app.booking_readiness_pre2920(uuid)'::regprocedure);

-- ================================================================ the renter's checklist
-- The coverage item from the one rule (what exactly is missing, and a link to that upload with its kind chosen); each
-- licence and selfie item links to its own upload on the page.
alter function app.renter_still_needed(uuid) rename to renter_still_needed_pre2920;
create function app.renter_still_needed(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.renter_still_needed_pre2920(p_booking);
  b bookings;
  s jsonb;
  i jsonb;
  v_items jsonb := '[]'::jsonb;
  v_need jsonb;
  v_kind text;
  v_driver text;
  v_labels text;
  v_sent text;
  u1 jsonb;
begin
  if x is null or jsonb_array_length(coalesce(x -> 'items', '[]'::jsonb)) = 0 then return x; end if;
  select * into b from bookings where id = p_booking;
  for i in select e from jsonb_array_elements(x -> 'items') e loop
    if i ->> 'key' = 'coverage' and i ->> 'status' <> 'done' then
      s := app.coverage_state(p_booking);
      v_need := coalesce(s -> 'needs', '[]'::jsonb);
      if s ->> 'proof_status' = 'rejected' then
        i := i || jsonb_build_object('action', jsonb_build_object('label', 'Send it again',
               'path', 'verify' || case when b.coverage_option = 1 then '?need=pink_slip#cov-pink_slip' else '#pt-cov' end));
      elsif jsonb_array_length(v_need) > 0 then
        select app.words_and(array_agg(n ->> 'label' order by o)) into v_labels from jsonb_array_elements(v_need) with ordinality q(n, o);
        v_kind := (select n ->> 'page_kind' from jsonb_array_elements(v_need) n where n ->> 'page_kind' is not null limit 1);
        -- the page already sent, said so: "We have your pink slip."
        v_sent := case when b.coverage_option = 1 and s ->> 'proof_status' = 'submitted' and jsonb_array_length(v_need) = 1 and v_kind is not null
                       then 'We have your ' || case v_kind when 'pink_slip' then 'OPCF 27 endorsement page' else 'pink slip' end || '. ' end;
        i := jsonb_build_object('key', 'coverage', 'status', 'missing',
          'label', case when b.coverage_option = 1 then 'Proof of coverage: send ' || v_labels else 'Proof of coverage: ' || v_labels end,
          'reason', coalesce(v_sent, '') || 'Still needed: ' || v_labels || '.',
          'action', jsonb_build_object('label', case v_kind when 'pink_slip' then 'Upload the pink slip' when 'endorsement' then 'Upload the endorsement page'
                                                 else case when b.coverage_option = 2 then 'Confirm your card' else 'Add the policy details' end end,
                                       'path', 'verify' || case when v_kind is not null then '?need=' || v_kind || '#cov-' || v_kind else '#pt-cov' end));
      elsif coalesce((s ->> 'proof_waiting')::boolean, false) then
        i := i || jsonb_build_object('status', 'review', 'reason', null, 'action', null);
      end if;
    elsif i ->> 'key' like 'licence:%' and i ->> 'status' in ('missing', 'rejected') then
      v_driver := split_part(i ->> 'key', ':', 2);
      u1 := app.sn_upload(p_booking, v_driver::uuid, 'licence_front');
      v_kind := case when u1 is null or u1 ->> 'status' = 'rejected' then 'licence_front' else 'licence_back' end;
      i := i || jsonb_build_object('action', jsonb_build_object('label', i #>> '{action,label}', 'path', 'verify#up-' || v_kind || '-' || v_driver));
    elsif i ->> 'key' like 'selfie:%' and i ->> 'status' in ('missing', 'rejected') then
      i := i || jsonb_build_object('action', jsonb_build_object('label', i #>> '{action,label}', 'path', 'verify#up-selfie-' || split_part(i ->> 'key', ':', 2)));
    end if;
    v_items := v_items || i;
  end loop;
  return jsonb_build_object('items', v_items,
    'done', (select count(*) from jsonb_array_elements(v_items) y where y ->> 'status' = 'done'),
    'total', jsonb_array_length(v_items),
    'complete', not exists (select 1 from jsonb_array_elements(v_items) y where y ->> 'status' <> 'done'));
end $$;
select pg_temp.copy_grants('app.renter_still_needed(uuid)'::regprocedure, 'app.renter_still_needed_pre2920(uuid)'::regprocedure);

revoke all on function app.coverage_state(uuid) from public, anon, authenticated;
grant execute on function app.coverage_state(uuid) to service_role;
