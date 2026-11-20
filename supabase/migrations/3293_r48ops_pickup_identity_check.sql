-- 3293 (release 48, operations screens): the pickup identity check. Is the person taking the car the renter?
-- The owner (Nov 20): at the pickup, the licence the person holds (3292's photo) is checked against what is on file:
-- name, licence number, expiry and face; and the payment card they show against the card on file and the name on the
-- ID. Any mismatch tells Fleet and Admin at once ("Possible wrong person at pickup") and marks the booking. Always
-- offered, never required, and never stops the check-in: this migration writes a record and raises a flag, nothing else.
--   1. pickup_identity_checks: one row for each check made. What was read off the licence shown (name, number, expiry),
--      one result for each thing compared (match, mismatch, unclear, not_checked), the reasons in plain words, who made
--      it. RLS on; written and read through the functions below only. No image of a payment card and no card number is
--      ever kept: the card is compared by the last four digits and the name, confirmed by the staff member looking at it.
--   2. app.pickup_identity_record(p_by, p): the comparing is done here, on the server's data. The caller passes what the
--      licence reader read and what the staff member confirmed; this function reads the driver's licence on file, the
--      card on file and the booking, and decides each result:
--        name     the name on the licence shown against the driver's name on the booking (app.person_names_match)
--        number   the licence number shown against the one on file (letters and digits only)
--        expiry   expired on the day, or a different date from the one on file
--        face     what the comparison of the faces answered: same, different or unsure (unsure flags nothing)
--        card_last4  staff: "the card shown ends in the four digits on file" yes or no
--        card_name   the cardholder name on file against the name on the ID (app.card_name_matches, skipped once an
--                    Admin accepted a different name), or the staff member's "the name on the card is not the name on
--                    the ID"
--      A mismatch: one urgent To do for Fleet and one for Admin, and the staff alert pickup_wrong_person. On a rental
--      covered by the renter's credit card (coverage option 2) a card that is not in the renter's name is also raised
--      as a coverage problem. The booking is marked for as long as one of those To do's is open.
--   3. app.pickup_identity_view(p_by, booking): what the step and the booking screens show: the driver and licence on
--      file, the card on file (brand, last four, cardholder name; staff only), the latest check and whether the booking
--      is marked. public.server_pickup_identity_source: for the server only, where the face on file is kept.
--   4. Evidence: the dispute pack carries every check of the booking (server_dispute_evidence.pickup_identity).
-- SCHEMA_MARKER 3293. docs/changes/2026-11-20-r48-ops-screens.md.
set local check_function_bodies = off;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g record;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  for g in select a.grantee::regrole::text as who from pg_proc p, aclexplode(p.proacl) a
            where p.oid = p_old and a.privilege_type = 'EXECUTE' and a.grantee <> 0 and a.grantee <> p.proowner loop
    execute format('grant execute on function %s to %s', p_new, g.who);
  end loop;
end $$;

-- ================================================================ 1. the record
create table pickup_identity_checks (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references bookings (id) on delete cascade,
  driver_id uuid not null references drivers (id),
  checked_by uuid references users (id),
  by_renter boolean not null default false,
  id_upload uuid references verification_uploads (id) on delete set null,
  selfie_upload uuid references verification_uploads (id) on delete set null,
  read_name text,
  read_number text,
  read_expiry date,
  name_result text not null default 'not_checked',
  number_result text not null default 'not_checked',
  expiry_result text not null default 'not_checked',
  face_result text not null default 'not_checked',
  card_last4_result text not null default 'not_checked',
  card_name_result text not null default 'not_checked',
  card_last4 text,
  outcome text not null,
  mismatches text[] not null default '{}',
  coverage_problem boolean not null default false,
  created_at timestamptz not null default now(),
  constraint pickup_identity_checks_results check (
    name_result in ('match', 'mismatch', 'unclear', 'not_checked') and number_result in ('match', 'mismatch', 'unclear', 'not_checked')
    and expiry_result in ('match', 'mismatch', 'unclear', 'not_checked') and face_result in ('match', 'mismatch', 'unclear', 'not_checked')
    and card_last4_result in ('match', 'mismatch', 'unclear', 'not_checked') and card_name_result in ('match', 'mismatch', 'unclear', 'not_checked')),
  constraint pickup_identity_checks_outcome check (outcome in ('match', 'mismatch', 'unclear')),
  -- the last four digits only: never a card number
  constraint pickup_identity_checks_last4 check (card_last4 is null or card_last4 ~ '^[0-9]{4}$'),
  constraint pickup_identity_checks_reasons check ((outcome = 'mismatch') = (cardinality(mismatches) > 0))
);
create index pickup_identity_checks_booking_idx on pickup_identity_checks (booking_id, created_at desc);
create index pickup_identity_checks_driver_idx on pickup_identity_checks (driver_id);
create index pickup_identity_checks_id_upload_idx on pickup_identity_checks (id_upload) where id_upload is not null;
create index pickup_identity_checks_selfie_upload_idx on pickup_identity_checks (selfie_upload) where selfie_upload is not null;
comment on table pickup_identity_checks is
  'The pickup identity check (3293): the licence shown at the pickup compared with the one on file, and the card shown with the card on file. Evidence only: it never stops a handover.';
alter table pickup_identity_checks enable row level security;
create policy pickup_identity_checks_office_read on pickup_identity_checks for select to authenticated
  using (app.is_admin() or app.va_has('cs', 'fleet', 'finance'));
revoke all on pickup_identity_checks from anon, authenticated;
grant select on pickup_identity_checks to authenticated;

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  ('pickup_wrong_person', 'Possible wrong person at pickup', 'Bookings', '{admin,on_duty:fleet}', 'urgent', 'alerts', true, false,
   'The licence or the card shown at a pickup did not match what is on file (3293). The booking has an urgent To do.', 60)
on conflict (rule) do nothing;

-- ================================================================ 2. the check
create function app.pickup_identity_marked(p_booking uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from tasks t where t.booking_id = p_booking and t.task_type in ('pickup_identity', 'pickup_card_coverage')
                    and t.status in ('open', 'in_progress', 'waiting'))
$$;

create function app.pickup_identity_record(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  d booking_drivers;
  pm payment_methods;
  v_staff boolean;
  v_driver uuid := case when coalesce(p ->> 'driver', '') ~ '^[0-9a-f-]{36}$' then (p ->> 'driver')::uuid end;
  v_id_up uuid := case when coalesce(p ->> 'id_upload', '') ~ '^[0-9a-f-]{36}$' then (p ->> 'id_upload')::uuid end;
  v_selfie_up uuid := case when coalesce(p ->> 'selfie_upload', '') ~ '^[0-9a-f-]{36}$' then (p ->> 'selfie_upload')::uuid end;
  r_name text := nullif(btrim(coalesce(p #>> '{read,name}', '')), '');
  r_num text := nullif(upper(regexp_replace(coalesce(p #>> '{read,number}', ''), '[^A-Za-z0-9]', '', 'g')), '');
  r_exp date := case when coalesce(p #>> '{read,expiry}', '') ~ '^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$' then to_date(p #>> '{read,expiry}', 'YYYY-MM-DD') end;
  v_face text := p ->> 'face';
  v_last4 text := p #>> '{card,last4}';
  v_cname text := p #>> '{card,name}';
  f_num text;
  n_res text := 'not_checked'; num_res text := 'not_checked'; e_res text := 'not_checked'; f_res text := 'not_checked';
  l4_res text := 'not_checked'; cn_res text := 'not_checked';
  v_why text[] := '{}';
  v_cov boolean := false;
  v_out text;
  v_id uuid;
  v_detail text;
begin
  select * into b from bookings where id = case when coalesce(p ->> 'booking', '') ~ '^[0-9a-f-]{36}$' then (p ->> 'booking')::uuid end;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  v_staff := app.user_may_handover(p_by);
  if p_by is null or not (v_staff or app.is_booking_renter(b.id, p_by)) then
    raise exception 'Only the staff handing the car over, or the renter of this booking, make the pickup identity check' using errcode = '42501';
  end if;
  if b.status not in ('confirmed', 'on_rent') then
    raise exception 'The identity check is made at the pickup: booking % is %', b.booking_number, b.status using errcode = '23514';
  end if;
  -- the driver: the one named, else the renter of the booking; a renter checks themselves only
  if v_driver is null or not v_staff then
    select x.driver_id into v_driver from booking_drivers x where x.booking_id = b.id and x.role = 'renter' order by x.driver_id limit 1;
  end if;
  select * into d from booking_drivers x where x.booking_id = b.id and x.driver_id = v_driver;
  if d.driver_id is null then raise exception 'That driver is not on this booking' using errcode = '23514'; end if;
  -- the photos named are this booking's own pickup photos
  if v_id_up is not null and not exists (select 1 from verification_uploads u where u.id = v_id_up and u.booking_id = b.id and u.status = 'at_pickup') then v_id_up := null; end if;
  if v_selfie_up is not null and not exists (select 1 from verification_uploads u where u.id = v_selfie_up and u.booking_id = b.id and u.status = 'at_pickup') then v_selfie_up := null; end if;

  if r_name is not null then
    n_res := case when app.person_names_match(r_name, d.full_name) then 'match' else 'mismatch' end;
    if n_res = 'mismatch' then v_why := v_why || format('The name on the licence shown (%s) is not the name on the booking (%s)', r_name, d.full_name); end if;
  end if;
  f_num := nullif(upper(regexp_replace(coalesce(d.licence_number, ''), '[^A-Za-z0-9]', '', 'g')), '');
  if r_num is not null and f_num is not null then
    num_res := case when r_num = f_num then 'match' else 'mismatch' end;
    if num_res = 'mismatch' then v_why := v_why || 'The licence number on the licence shown is not the one on file'::text; end if;
  end if;
  if r_exp is not null then
    if r_exp < app.today() then
      e_res := 'mismatch'; v_why := v_why || format('The licence shown expired on %s', to_char(r_exp, 'FMMonth FMDD, YYYY'));
    elsif d.licence_expiry is not null and d.licence_expiry <> r_exp then
      e_res := 'mismatch'; v_why := v_why || format('The expiry on the licence shown (%s) is not the one on file (%s)', to_char(r_exp, 'FMMonth FMDD, YYYY'), to_char(d.licence_expiry, 'FMMonth FMDD, YYYY'));
    elsif d.licence_expiry is not null then e_res := 'match';
    end if;
  end if;
  if v_face in ('same', 'different', 'unsure') then
    f_res := case v_face when 'same' then 'match' when 'different' then 'mismatch' else 'unclear' end;
    if f_res = 'mismatch' then v_why := v_why || 'The face does not look like the photo on file'::text; end if;
  end if;

  -- the payment card: by its last four digits and its name. Never an image, never the number.
  select m.* into pm from payment_methods m where m.id = b.card_on_file_id;
  if v_staff and pm.id is not null and v_last4 in ('yes', 'no') then
    l4_res := case v_last4 when 'yes' then 'match' else 'mismatch' end;
    if l4_res = 'mismatch' then v_why := v_why || format('The card shown does not end in %s, the card on file', pm.card_last4); end if;
  end if;
  if v_staff and v_cname in ('yes', 'no') then
    cn_res := case v_cname when 'yes' then 'match' else 'mismatch' end;
    if cn_res = 'mismatch' then v_why := v_why || 'The name on the card shown is not the name on the ID'::text; end if;
  end if;
  if cn_res <> 'mismatch' and r_name is not null and nullif(btrim(coalesce(pm.cardholder_name, '')), '') is not null and b.card_name_accepted_at is null then
    if app.card_name_matches(pm.cardholder_name, r_name) then cn_res := 'match';
    else cn_res := 'mismatch'; v_why := v_why || format('The cardholder name on file (%s) is not the name on the licence shown (%s)', pm.cardholder_name, r_name);
    end if;
  end if;
  v_cov := cn_res = 'mismatch' and coalesce(b.coverage_option = 2, false);

  v_out := case when cardinality(v_why) > 0 then 'mismatch'
                when 'unclear' in (n_res, num_res, e_res, f_res) or 'match' not in (n_res, num_res, e_res, f_res, l4_res, cn_res) then 'unclear'
                else 'match' end;
  insert into pickup_identity_checks (booking_id, driver_id, checked_by, by_renter, id_upload, selfie_upload, read_name, read_number, read_expiry,
      name_result, number_result, expiry_result, face_result, card_last4_result, card_name_result, card_last4, outcome, mismatches, coverage_problem)
  values (b.id, v_driver, p_by, not v_staff, v_id_up, v_selfie_up, r_name, r_num, r_exp, n_res, num_res, e_res, f_res, l4_res, cn_res,
      case when l4_res = 'match' then pm.card_last4 end, v_out, v_why, v_cov)
  returning id into v_id;

  if v_out = 'mismatch' then
    v_detail := format('Booking %s, %s. %s. Look at the pickup photo beside the licence on file before the car leaves, or call the staff member at the car.',
                       b.booking_number, d.full_name, array_to_string(v_why, '. '));
    perform app.raise_task('pickup_identity', 'Possible wrong person at pickup: ' || b.booking_number, v_detail, b.id, b.vehicle_id, null, b.renter_id,
                           'bookings', b.id, now(), 'urgent', 'pickup_identity:' || b.id || ':fleet', 'fleet', p_by);
    perform app.raise_task('pickup_identity', 'Possible wrong person at pickup: ' || b.booking_number, v_detail, b.id, b.vehicle_id, null, b.renter_id,
                           'bookings', b.id, now(), 'urgent', 'pickup_identity:' || b.id || ':admin', 'admin', p_by);
    if v_cov then
      perform app.raise_task('pickup_card_coverage', 'Coverage problem at pickup: the card is not in the renter''s name, ' || b.booking_number,
                             format('Booking %s is covered by the renter''s credit card, and the card must be in the renter''s own name. %s.', b.booking_number, array_to_string(v_why, '. ')),
                             b.id, b.vehicle_id, null, b.renter_id, 'bookings', b.id, now(), 'urgent', 'pickup_card_coverage:' || b.id, 'admin', p_by);
    end if;
    perform app.staff_alert('pickup_wrong_person', 'booking', b.id, v_id::text, 'Possible wrong person at pickup: ' || b.booking_number,
                            array_to_string(v_why, '. '), jsonb_build_object('path_admin', '/admin/bookings/' || b.booking_number, 'path_staff', '/staff/bookings/' || b.booking_number));
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'pickup_identity_check', 'bookings', b.id, jsonb_build_object('check', v_id, 'outcome', v_out, 'by_renter', not v_staff));
  return jsonb_build_object('id', v_id, 'outcome', v_out, 'mismatches', to_jsonb(v_why), 'coverage_problem', v_cov,
    'results', jsonb_build_object('name', n_res, 'number', num_res, 'expiry', e_res, 'face', f_res, 'card_last4', l4_res, 'card_name', cn_res));
end $$;

create function public.server_pickup_identity_record(p_by uuid, p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.pickup_identity_record(p_by, p) $$;

-- ================================================================ 3. what the screens show
create function app.pickup_identity_view(p_by uuid, p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  v_staff boolean;
  v_last jsonb;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return null; end if;
  v_staff := app.user_may_handover(p_by) or app.doc_review_can(p_by, b.id);
  if p_by is null or not (v_staff or app.is_booking_renter(b.id, p_by)) then return null; end if;
  select jsonb_build_object('id', c.id, 'at', c.created_at, 'outcome', c.outcome, 'by_renter', c.by_renter,
           'by', (select u.full_name from users u where u.id = c.checked_by),
           'mismatches', case when v_staff then to_jsonb(c.mismatches) else '[]'::jsonb end, 'coverage_problem', c.coverage_problem and v_staff,
           'read', case when v_staff then jsonb_build_object('name', c.read_name, 'number', c.read_number, 'expiry', c.read_expiry) end,
           'results', jsonb_build_object('name', c.name_result, 'number', c.number_result, 'expiry', c.expiry_result, 'face', c.face_result,
                                         'card_last4', c.card_last4_result, 'card_name', c.card_name_result))
    into v_last
    from pickup_identity_checks c where c.booking_id = b.id order by c.created_at desc, c.id desc limit 1;
  return jsonb_build_object(
    'booking_id', b.id, 'booking_number', b.booking_number, 'staff', v_staff,
    'open', b.status in ('confirmed', 'on_rent'),
    'booking_name', (select r.legal_name from renters r where r.id = b.renter_id),
    'coverage_card', coalesce(b.coverage_option = 2, false),
    'marked', v_staff and app.pickup_identity_marked(b.id),
    'drivers', (select coalesce(jsonb_agg(jsonb_build_object('driver_id', x.driver_id, 'name', x.full_name, 'role', x.role,
                         'licence_number', case when v_staff then x.licence_number end, 'licence_expiry', case when v_staff then x.licence_expiry end,
                         'on_file', case when v_staff then (select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'kind', u.kind) order by u.kind), '[]'::jsonb)
                              from verification_uploads u join documents doc on doc.id = u.document_id
                             where u.booking_id = b.id and u.driver_id = x.driver_id and u.kind in ('licence_front', 'selfie') and u.status = 'approved' and doc.purged_at is null) end,
                         'at_pickup', case when v_staff then (select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'kind', u.kind) order by u.kind), '[]'::jsonb)
                              from verification_uploads u join documents doc on doc.id = u.document_id
                             where u.booking_id = b.id and u.driver_id = x.driver_id and u.status = 'at_pickup' and doc.purged_at is null) end)
                       order by (x.role = 'renter') desc, x.full_name), '[]'::jsonb)
                  from booking_drivers x where x.booking_id = b.id),
    'card', case when v_staff then (select jsonb_build_object('brand', m.card_brand, 'last4', m.card_last4, 'name', m.cardholder_name)
                                      from payment_methods m where m.id = b.card_on_file_id) end,
    'last', v_last);
end $$;

create function public.server_pickup_identity_view(p_by uuid, p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.pickup_identity_view(p_by, p_booking) $$;

-- for the server only: the face on file to compare with (the approved selfie, else the approved licence front)
create function public.server_pickup_identity_source(p_by uuid, p_booking uuid, p_driver uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('bucket', doc.storage_bucket, 'path', doc.storage_path, 'kind', u.kind)
    from verification_uploads u join documents doc on doc.id = u.document_id
   where u.booking_id = p_booking and u.driver_id = p_driver and u.kind in ('selfie', 'licence_front') and u.status = 'approved'
     and doc.purged_at is null and doc.storage_path is not null
     and (app.user_may_handover(p_by) or app.is_booking_renter(p_booking, p_by))
   order by (u.kind = 'selfie') desc, u.uploaded_at desc limit 1
$$;

-- ================================================================ 4. evidence
alter function public.server_dispute_evidence(uuid) rename to server_dispute_evidence_pre3293;
create function public.server_dispute_evidence(p_pack uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := public.server_dispute_evidence_pre3293(p_pack);
begin
  if v is null then return v; end if;
  return v || jsonb_build_object('pickup_identity', (
    select coalesce(jsonb_agg(jsonb_build_object('at', c.created_at, 'driver', (select dv.full_name from drivers dv where dv.id = c.driver_id),
               'by', case when c.by_renter then 'the renter, at the self check-in' else coalesce((select u.full_name from users u where u.id = c.checked_by), 'staff') end,
               'outcome', c.outcome, 'mismatches', to_jsonb(c.mismatches),
               'results', jsonb_build_object('name', c.name_result, 'number', c.number_result, 'expiry', c.expiry_result, 'face', c.face_result,
                                             'card_last4', c.card_last4_result, 'card_name', c.card_name_result),
               'card_last4', c.card_last4) order by c.created_at), '[]'::jsonb)
      from dispute_packs k join pickup_identity_checks c on c.booking_id = k.booking_id where k.id = p_pack));
end $$;
select pg_temp.copy_grants('public.server_dispute_evidence(uuid)'::regprocedure, 'public.server_dispute_evidence_pre3293(uuid)'::regprocedure);

-- ================================================================ privileges
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['pickup_identity_marked', 'pickup_identity_record', 'pickup_identity_view']))
        or (n.nspname = 'public' and p.proname = any (array['server_pickup_identity_record', 'server_pickup_identity_view', 'server_pickup_identity_source', 'server_dispute_evidence_pre3293']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
