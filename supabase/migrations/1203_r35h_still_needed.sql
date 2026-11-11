-- 1203_r35h_still_needed.sql
-- Release 35, part H (docs/changes/2026-11-09-r35-offer-pricing-extensions-coverage.md), item 5.
-- The owner: the renter's portal must be "super clear about things that are still needed from them, especially during
-- requests and bookings that aren't 100% complete yet". app.renter_still_needed(booking) is the one list: what the
-- booking requires of the renter, each item with its status (missing, review, rejected with the reason, done) and its
-- one action, from the same facts the staff side reads (app.booking_readiness, app.sign_pay_state, the uploads, the
-- drivers). The renter's booking read (public.my_booking) and list (public.my_bookings) carry it for the checklist at
-- the top of /account and of each request and booking; the reminders ("Still missing: ...") name the same items.
set local check_function_bodies = off;

create or replace function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- the latest upload of a kind for a driver (or the booking's, for coverage): its status and reason
create function app.sn_upload(p_booking uuid, p_driver uuid, p_kind text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('status', u.status, 'reason', u.reject_reason)
    from verification_uploads u
   where u.booking_id = p_booking and u.kind = p_kind and (p_driver is null or u.driver_id = p_driver) and u.status in ('submitted', 'approved', 'rejected')
   order by u.uploaded_at desc limit 1
$$;

-- an item: key, label, status, reason, action (label and the page under the booking, or an /account path)
create function app.sn_item(p_key text, p_label text, p_status text, p_reason text, p_action text, p_path text) returns jsonb
language sql immutable as $$
  select jsonb_build_object('key', p_key, 'label', p_label, 'status', p_status, 'reason', p_reason,
           'action', case when p_status <> 'done' and p_action is not null then jsonb_build_object('label', p_action, 'path', p_path) end)
$$;

create function app.renter_still_needed(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  rn renters;
  r jsonb;
  sp jsonb;
  d record;
  u1 jsonb; u2 jsonb;
  v_items jsonb := '[]'::jsonb;
  v_docs boolean;
  v_st text;
  v_reason text;
  v_cov jsonb;
  v_paid boolean;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null or b.booking_type = 'owner' or b.status::text not in ('requested', 'offered', 'pending_payment', 'confirmed', 'on_rent') then
    return jsonb_build_object('items', '[]'::jsonb, 'done', 0, 'total', 0, 'complete', true);
  end if;
  select * into rn from renters where id = b.renter_id;
  r := app.booking_readiness(b.id);
  sp := case when b.status::text in ('offered', 'pending_payment', 'confirmed', 'on_rent') then app.sign_pay_state(b.id) end;
  v_docs := b.status::text in ('pending_payment', 'confirmed', 'on_rent');

  -- a request: our open question; an offer: approve it
  if b.status::text = 'requested' and exists (select 1 from booking_info_requests q where q.booking_id = b.id and q.status = 'open') then
    v_items := v_items || app.sn_item('question', 'Answer our question', 'missing', null, 'Answer', '#questions');
  end if;
  if b.status::text = 'offered' then
    v_items := v_items || app.sn_item('offer', 'Approve your offer', 'missing', null, 'Review the offer', 'offer');
  end if;

  -- the renter's own details
  v_items := v_items || app.sn_item('dob', 'Your date of birth', case when rn.date_of_birth is null then 'missing' else 'done' end, null, 'Add it', '/account/profile');
  v_items := v_items || app.sn_item('address', 'Your home address', case when nullif(btrim(coalesce(rn.address_line1, '')), '') is null then 'missing' else 'done' end, null, 'Add it', '/account/profile');

  -- signing and paying (the one rule, 0750)
  if sp is not null and b.status::text <> 'offered' then
    v_items := v_items || app.sn_item('signature', 'Sign the rental agreement',
      case when sp ->> 'step' = 'sign' then 'missing' when sp ->> 'step' = 'drivers' then 'review'
           when coalesce((sp ->> 'signed')::boolean, false) or coalesce((r ->> 'agreement_completed')::boolean, false) or b.status::text = 'on_rent' then 'done'
           when b.status::text = 'pending_payment' then 'missing' else 'done' end,
      case when sp ->> 'step' = 'drivers' then 'Waiting for ' || coalesce((select string_agg(x, ', ') from jsonb_array_elements_text(sp -> 'waiting') x), 'another driver') || ' to sign' end,
      'Sign', 'checkout');
    v_paid := exists (select 1 from payments p where p.booking_id = b.id and p.purpose = 'booking_total' and p.kind = 'charge' and p.status = 'succeeded')
              or b.status::text in ('confirmed', 'on_rent') and sp ->> 'step' <> 'pay';
    v_items := v_items || app.sn_item('payment', 'Pay for the booking', case when sp ->> 'step' = 'pay' or not v_paid then 'missing' else 'done' end, null, 'Pay', 'checkout');
  end if;

  -- each driver's licence and selfie (once the car is booked)
  if v_docs then
    for d in select x.driver_id, x.full_name, x.role, x.identity_verified_on, x.accepted_at from booking_drivers x where x.booking_id = b.id order by x.role desc, x.full_name loop
      u1 := app.sn_upload(b.id, d.driver_id, 'licence_front');
      u2 := app.sn_upload(b.id, d.driver_id, 'licence_back');
      v_st := case when d.identity_verified_on is not null then 'done'
                   when u1 ->> 'status' = 'rejected' or u2 ->> 'status' = 'rejected' then 'rejected'
                   when u1 is not null and u2 is not null then case when u1 ->> 'status' = 'approved' and u2 ->> 'status' = 'approved' then 'done' else 'review' end
                   else 'missing' end;
      v_reason := case when v_st = 'rejected' then coalesce(nullif(u1 ->> 'reason', ''), nullif(u2 ->> 'reason', ''), 'Not accepted: send it again') end;
      v_items := v_items || app.sn_item('licence:' || d.driver_id, case when d.role = 'renter' then 'Your driver''s licence (front and back)' else 'Licence of ' || d.full_name || ' (front and back)' end,
                                         v_st, v_reason, case when v_st = 'rejected' then 'Upload again' else 'Upload' end, 'verify');
      u1 := app.sn_upload(b.id, d.driver_id, 'selfie');
      v_st := case when d.identity_verified_on is not null then 'done' when u1 is null then 'missing' when u1 ->> 'status' = 'approved' then 'done'
                   when u1 ->> 'status' = 'rejected' then 'rejected' else 'review' end;
      v_items := v_items || app.sn_item('selfie:' || d.driver_id, case when d.role = 'renter' then 'A selfie holding your licence' else 'A selfie of ' || d.full_name || ' with the licence' end,
                                         v_st, case when v_st = 'rejected' then coalesce(nullif(u1 ->> 'reason', ''), 'Not accepted: take it again') end,
                                         case when v_st = 'rejected' then 'Take it again' else 'Take the selfie' end, 'verify');
      if d.role = 'additional' then
        v_items := v_items || app.sn_item('accept:' || d.driver_id, d.full_name || ' accepts the rental terms', case when d.accepted_at is not null then 'done' else 'missing' end,
                                           case when d.accepted_at is null then 'We sent them a link by email' end, 'See the drivers', '#drivers');
      end if;
    end loop;
    -- proof of coverage (own policy or card; the Protection Plan and insurance included need none)
    if coalesce(b.coverage_option, 0) in (1, 2) then
      v_cov := app.sn_upload(b.id, null, 'coverage_proof');
      v_st := case when b.coverage_confirmed_at is not null then 'done' when v_cov is null then 'missing' when v_cov ->> 'status' = 'rejected' then 'rejected'
                   when v_cov ->> 'status' = 'approved' then 'done' else 'review' end;
      v_items := v_items || app.sn_item('coverage', case when b.coverage_option = 1 then 'Proof of coverage (OPCF 27 on your policy)' else 'Proof of your credit card rental coverage' end,
                                         v_st, case when v_st = 'rejected' then coalesce(nullif(v_cov ->> 'reason', ''), 'Not accepted: send it again') end,
                                         case when v_st = 'rejected' then 'Send it again' else 'Send it' end, 'verify');
    end if;
    -- the deposit: held on the card before pickup
    if coalesce(b.deposit_cents, 0) > 0 and b.status::text in ('confirmed', 'on_rent') then
      v_items := v_items || app.sn_item('deposit', 'Deposit ' || app.fmt_money(b.deposit_cents),
        case when coalesce((r ->> 'deposit_ok')::boolean, false) then 'done' when b.card_on_file_id is null then 'missing' else 'review' end,
        case when not coalesce((r ->> 'deposit_ok')::boolean, false) and b.card_on_file_id is not null then 'We hold it on your card before pickup' end,
        'Add a card', '/account/profile');
    end if;
  end if;

  return jsonb_build_object('items', v_items,
    'done', (select count(*) from jsonb_array_elements(v_items) x where x ->> 'status' = 'done'),
    'total', jsonb_array_length(v_items),
    'complete', not exists (select 1 from jsonb_array_elements(v_items) x where x ->> 'status' <> 'done'));
end $$;
comment on function app.renter_still_needed(uuid) is 'What a booking still needs from the renter (1203): items with status missing, review, rejected (with the reason) or done, and one action each. The portal''s checklist and the reminders read it.';

-- the renter's own (the reads below run with the renter's rights; this one checks the booking is theirs)
create function app.my_still_needed(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when app.is_booking_renter(p_booking, app.uid()) then app.renter_still_needed(p_booking) end
$$;

-- the renter's reads carry it
-- the bodies move to app (a signed-in session keeps calling them through the wrappers, with its own rights)
alter function public.my_booking(text) set schema app;
alter function app.my_booking(text) rename to my_booking_pre1203;
create function public.my_booking(p_number text) returns jsonb
language sql stable set search_path = public, app as $$
  select case when x is null then null else x || jsonb_build_object('still_needed', app.my_still_needed((x ->> 'id')::uuid)) end
    from (select app.my_booking_pre1203(p_number) as x) q
$$;
select pg_temp.copy_grants('public.my_booking(text)'::regprocedure, 'app.my_booking_pre1203(text)'::regprocedure);

alter function public.my_bookings() set schema app;
alter function app.my_bookings() rename to my_bookings_pre1203;
create function public.my_bookings() returns setof jsonb
language sql stable set search_path = public, app as $$
  select x || jsonb_build_object('still_needed', case when x ->> 'status' in ('requested', 'offered', 'pending_payment', 'confirmed', 'on_rent') then app.my_still_needed((x ->> 'id')::uuid) end)
    from app.my_bookings_pre1203() x
$$;
select pg_temp.copy_grants('public.my_bookings()'::regprocedure, 'app.my_bookings_pre1203()'::regprocedure);

-- the reminders name the same items: "Still missing: ..." lists every item not done
alter function app.ntf_booking(uuid) rename to ntf_booking_pre1203;
create function app.ntf_booking(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_booking_pre1203(p_booking);
  s jsonb;
  v_text text;
begin
  if x is null or p_booking is null then return x; end if;
  s := app.renter_still_needed(p_booking);
  select app.words_and(array_agg(lower(left(i ->> 'label', 1)) || substr(i ->> 'label', 2) order by n)) into v_text
    from jsonb_array_elements(s -> 'items') with ordinality e(i, n) where i ->> 'status' in ('missing', 'rejected');
  return x || jsonb_build_object('still_needed', s, 'still_needed_text', v_text)
           || case when v_text is not null then jsonb_build_object('needed_items', v_text) else '{}'::jsonb end;
end $$;
select pg_temp.copy_grants('app.ntf_booking(uuid)'::regprocedure, 'app.ntf_booking_pre1203(uuid)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['sn_upload', 'sn_item', 'renter_still_needed', 'ntf_booking_pre1203'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
  -- the renter's reads keep running with the renter's rights: the bodies they wrap keep their grants
  execute 'revoke all on function app.my_still_needed(uuid) from public, anon';
  execute 'grant execute on function app.my_still_needed(uuid) to authenticated, service_role';
end $$;
