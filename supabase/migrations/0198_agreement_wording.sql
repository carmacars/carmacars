-- 0198: the rental agreement's wording, per booking (the owner, October 30: "make the rental agreement editable").
-- SCHEMA_MARKER 0198. docs/changes/2026-10-30-agreement-wording.md.
--   An Admin rewords a clause of CarmaCars' rental agreement for one booking, adds "Additional terms", or removes a
--   clause that is not required, always with a reason (booking_clause_overrides, kept in full: the latest row of a
--   clause is in force). Clauses required by law or the insurer (coverage, damage, the consents...) are reworded, never
--   removed; the consents the signer ticks are not reworded at all. Blind Spot's form is the insurer's official form:
--   nothing here changes it.
--   The wording is part of what the agreement prints (app.agreement_snapshot, key "wording"): before signing the open
--   agreement is rendered again; after signing a change is a new version the renter and the drivers sign (material),
--   through the version plan of 0154, and the version history shows each clause before and after.
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

-- ================================================================ 1. the clauses (web/src/features/agreement/wording.ts CLAUSES)
create table if not exists agreement_clauses (
  code       text primary key,
  part       text not null check (part in ('2', '3', '5', '6', 'extra')),
  title      text not null,
  sort       integer not null,
  removable  boolean not null default false,
  editable   boolean not null default true
);
comment on table agreement_clauses is 'The clauses of CarmaCars'' rental agreement an Admin may reword per booking (0198); removable false: required by law or the insurer.';
insert into agreement_clauses (code, part, title, sort, removable, editable) values
  ('definitions', '2', '1. Definitions and structure', 1, false, true),
  ('drivers', '2', '2. Drivers', 2, false, true),
  ('rental_period', '2', '3. Rental period', 3, false, true),
  ('pickup_return', '2', '4. Pickup and return', 4, false, true),
  ('charges', '2', '5. Charges, Deposit and payment', 5, false, true),
  ('tolls', '2', '6. Tolls, tickets and fines', 6, true, true),
  ('cancellation', '2', '7. Cancellation', 7, false, true),
  ('coverage', '2', '8. Coverage', 8, false, true),
  ('damage', '2', '9. Damage', 9, false, true),
  ('use', '2', '10. Use of the Vehicle', 10, false, true),
  ('accidents', '2', '11. Accidents, theft and breakdown', 11, false, true),
  ('tracking', '2', '12. Tracking, disabling and repossession', 12, false, true),
  ('privacy', '2', '13. Personal information', 13, false, true),
  ('liability', '2', '14. Limits on our liability', 14, false, true),
  ('general', '2', '15. General', 15, false, true),
  ('fee_schedule', '3', 'Part 3: Schedule of Fees', 16, false, true),
  ('owner_addendum', '5', 'Part 5: Owner Rental Addendum', 17, false, true),
  ('consents', '6', 'Part 6: Booking Consents', 18, false, false),
  ('additional', 'extra', 'Additional terms for this booking', 19, true, true)
on conflict (code) do update set part = excluded.part, title = excluded.title, sort = excluded.sort, removable = excluded.removable, editable = excluded.editable;

-- ================================================================ 2. the booking's changes, every one kept
create table if not exists booking_clause_overrides (
  id           uuid primary key default gen_random_uuid(),
  booking_id   uuid not null references bookings (id) on delete cascade,
  clause_code  text not null references agreement_clauses (code),
  action       text not null check (action in ('edit', 'add', 'remove', 'restore')),
  text         text check (text is null or length(text) <= 20000),
  reason       text not null check (length(btrim(reason)) >= 5),
  by_user      uuid not null references users (id),
  created_at   timestamptz not null default now(),
  check ((action in ('edit', 'add')) = (text is not null and length(btrim(text)) > 0))
);
create index if not exists booking_clause_overrides_booking on booking_clause_overrides (booking_id, clause_code, created_at desc);
comment on table booking_clause_overrides is 'An Admin''s wording of a rental agreement clause for one booking (0198): edit, add (additional terms), remove (optional clauses only) or restore the standard; every change kept with its reason. The latest row of a clause is in force.';
alter table booking_clause_overrides enable row level security;
alter table agreement_clauses enable row level security;
create policy admin_all on booking_clause_overrides for all to authenticated using (app.is_admin()) with check (app.is_admin());
create policy admin_all on agreement_clauses for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on booking_clause_overrides, agreement_clauses from anon, authenticated;
grant select, insert on booking_clause_overrides to service_role;
grant select on agreement_clauses to service_role;
create trigger audit_agreement_clauses after insert or update or delete on agreement_clauses for each row execute function app.audit_row();
create trigger audit_booking_clause_overrides after insert or update or delete on booking_clause_overrides for each row execute function app.audit_row();

-- history only: a change is never edited or deleted (a booking deleted takes its rows with it)
create or replace function app.booking_clause_overrides_append_only() returns trigger
language plpgsql as $$
begin
  raise exception 'The wording history of a booking is kept as written' using errcode = '42501';
end $$;
create trigger booking_clause_overrides_append_only before update on booking_clause_overrides for each row execute function app.booking_clause_overrides_append_only();

-- booking history kind
do $$
declare
  c record;
  v_kinds text[];
begin
  select conname, pg_get_constraintdef(oid) as def into strict c from pg_constraint
   where conrelid = 'public.booking_events'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%kind%';
  select array_agg(distinct m[1]) into v_kinds from regexp_matches(c.def, '[''{,]([a-z_0-9]+)(?=[''},])', 'g') m;
  select array_agg(distinct x order by x) into v_kinds from unnest(v_kinds || array['agreement_wording']) x;
  execute format('alter table public.booking_events drop constraint %I', c.conname);
  execute format('alter table public.booking_events add constraint booking_events_kind_check check (kind in (%s))',
                 (select string_agg(quote_literal(x), ', ') from unnest(v_kinds) x));
end $$;

-- The wording in force: {code: {action, text}}, standard clauses absent ({} when all is standard).
create or replace function app.agreement_wording(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_object_agg(o.clause_code, jsonb_build_object('action', o.action, 'text', o.text)), '{}'::jsonb)
    from (select distinct on (clause_code) clause_code, action, text from booking_clause_overrides
           where booking_id = p_booking order by clause_code, created_at desc, id desc) o
   where o.action <> 'restore'
$$;

create or replace function public.server_agreement_wording(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.agreement_wording(p_booking) $$;

-- ================================================================ 3. the snapshot, the change list, the plan
-- The wording is in the snapshot only when a clause is changed: every other booking's snapshot stays as it was.
alter function app.agreement_snapshot(uuid) rename to agreement_snapshot_pre0198;
create or replace function app.agreement_snapshot(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s jsonb := app.agreement_snapshot_pre0198(p_booking);
  w jsonb;
begin
  if s is null then return null; end if;
  select coalesce(jsonb_object_agg(key, case when value ->> 'action' = 'remove' then '[removed]' else value ->> 'text' end), '{}'::jsonb)
    into w from jsonb_each(app.agreement_wording(p_booking));
  return case when w = '{}'::jsonb then s else s || jsonb_build_object('wording', w) end;
end $$;
select pg_temp.copy_grants('app.agreement_snapshot(uuid)'::regprocedure, 'app.agreement_snapshot_pre0198(uuid)'::regprocedure);

alter function app.agreement_key_label(text, jsonb) rename to agreement_key_label_pre0198;
create or replace function app.agreement_key_label(p_key text, p_names jsonb default '{}'::jsonb, out label text, out material boolean)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_key like 'wording.%' then
    label := 'Agreement wording: ' || coalesce((select c.title from agreement_clauses c where c.code = substr(p_key, 9)), substr(p_key, 9));
    material := true;  -- the renter signs what they agree to
    return;
  end if;
  select l.label, l.material into label, material from app.agreement_key_label_pre0198(p_key, p_names) l;
end $$;
select pg_temp.copy_grants('app.agreement_key_label(text, jsonb)'::regprocedure, 'app.agreement_key_label_pre0198(text, jsonb)'::regprocedure);

alter function app.agreement_key_value(text, text) rename to agreement_key_value_pre0198;
create or replace function app.agreement_key_value(p_key text, p_value text) returns text
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_key like 'wording.%' then
    return case when p_value is null then case when p_key = 'wording.additional' then '(none)' else 'Standard wording' end
                when p_value = '[removed]' then 'Removed' else p_value end;
  end if;
  return app.agreement_key_value_pre0198(p_key, p_value);
end $$;
select pg_temp.copy_grants('app.agreement_key_value(text, text)'::regprocedure, 'app.agreement_key_value_pre0198(text, text)'::regprocedure);

-- A wording change after signing is signed again by the renter and every additional driver (the terms bind them all),
-- even when an amendment was signed since the last version (the amendment did not carry the wording).
alter function app.agreement_plan(uuid) rename to agreement_plan_pre0198;
create or replace function app.agreement_plan(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  pl jsonb := app.agreement_plan_pre0198(p_booking);
  v_signers jsonb;
begin
  if pl ->> 'state' <> 'version' or not exists (select 1 from jsonb_array_elements(pl -> 'changes') x where x ->> 'key' like 'wording.%') then
    return pl;
  end if;
  select coalesce(jsonb_agg(s order by s ->> 'role' desc, s ->> 'name'), '[]'::jsonb) into v_signers from (
    select jsonb_build_object('role', 'renter', 'booking_driver_id', d.id, 'user_id', r.user_id, 'name', coalesce(r.legal_name, d.full_name),
                              'email', coalesce(nullif(r.email, ''), (select u.email from users u where u.id = r.user_id)),
                              'mobile', coalesce(r.mobile, (select u.phone from users u where u.id = r.user_id))) as s
      from bookings b join renters r on r.id = b.renter_id left join booking_drivers d on d.booking_id = b.id and d.role = 'renter' where b.id = p_booking
    union all
    select jsonb_build_object('role', 'additional_driver', 'booking_driver_id', d.id, 'user_id', dv.user_id, 'name', d.full_name, 'email', dv.email, 'mobile', dv.mobile)
      from booking_drivers d join drivers dv on dv.id = d.driver_id where d.booking_id = p_booking and d.role = 'additional') q;
  return pl || jsonb_build_object('material', true, 'kind', case when pl ->> 'kind' = 'correction' then 'change' else pl ->> 'kind' end,
                                  'signers', v_signers, 'amendment_id', null, 'amendment_number', null, 'wording_changed', true);
end $$;
select pg_temp.copy_grants('app.agreement_plan(uuid)'::regprocedure, 'app.agreement_plan_pre0198(uuid)'::regprocedure);

-- ================================================================ 4. an Admin changes the wording
-- p: booking, code, action (edit, add, remove, restore), text (edit and add), reason.
create or replace function app.agreement_wording_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  c agreement_clauses;
  a rental_agreements;
  v_action text := lower(btrim(coalesce(p ->> 'action', '')));
  v_text text := nullif(btrim(coalesce(p ->> 'text', '')), '');
  v_reason text := btrim(coalesce(p ->> 'reason', ''));
  v_now jsonb;
  v_id uuid;
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin changes the wording of the rental agreement' using errcode = '42501'; end if;
  select * into b from bookings where id = (p ->> 'booking')::uuid for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.status::text not in ('requested', 'offered', 'tentative', 'pending_payment', 'confirmed', 'on_rent', 'returned') then
    raise exception 'This booking is %: its agreement is no longer changed', replace(b.status::text, '_', ' ') using errcode = '23514';
  end if;
  select * into c from agreement_clauses where code = p ->> 'code';
  if c.code is null then raise exception 'Choose a clause of the agreement' using errcode = '22023'; end if;
  if v_action = 'add' and c.code <> 'additional' then v_action := 'edit'; end if;
  if v_action = 'edit' and c.code = 'additional' then v_action := 'add'; end if;
  if v_action not in ('edit', 'add', 'remove', 'restore') then raise exception 'Choose edit, add, remove or restore' using errcode = '22023'; end if;
  if not c.editable then raise exception '% is worded as the signer ticks it and is not changed per booking', c.title using errcode = '23514'; end if;
  if v_action = 'remove' and not c.removable then
    raise exception '% is required by law or the insurer: it can be reworded, not removed', c.title using errcode = '23514';
  end if;
  if v_action in ('edit', 'add') and v_text is null then raise exception 'Write the clause''s text' using errcode = '22023'; end if;
  if v_text is not null and length(v_text) > 20000 then raise exception 'The clause''s text, up to 20,000 characters' using errcode = '22023'; end if;
  if length(v_reason) < 5 then raise exception 'Say why the wording changes for this booking' using errcode = '22023'; end if;
  -- signed and not countersigned yet (or signed by one person on an open agreement): the document they signed stays as is
  select * into a from rental_agreements where booking_id = b.id and status in ('open', 'signed', 'completed') order by opened_at desc limit 1;
  if a.status = 'signed' or (a.status = 'open' and exists (select 1 from rental_agreement_signers g where g.agreement_id = a.id and g.signed_at is not null)) then
    raise exception 'The agreement is being signed: change the wording once it is countersigned (it then becomes a new version to sign)' using errcode = '23514';
  end if;
  v_now := app.agreement_wording(b.id) -> c.code;
  if (v_action = 'restore' and v_now is null)
     or (v_action = 'remove' and v_now ->> 'action' = 'remove')
     or (v_action in ('edit', 'add') and v_now ->> 'text' = v_text) then
    raise exception 'Nothing changes: the clause already reads that way' using errcode = '23514';
  end if;
  insert into booking_clause_overrides (booking_id, clause_code, action, text, reason, by_user)
  values (b.id, c.code, v_action, case when v_action in ('edit', 'add') then v_text end, v_reason, p_by) returning id into v_id;
  perform app.log_booking_event(b.id, 'agreement_wording', b.status::text, b.status::text, null,
    format('Agreement wording, %s: %s. Reason: %s', c.title,
           case v_action when 'edit' then 'reworded' when 'add' then 'written' when 'remove' then 'removed' else 'back to the standard wording' end, v_reason),
    p_by, 'staff', jsonb_build_object('override_id', v_id, 'clause', c.code, 'action', v_action));
  perform app.agreement_touch(b.id);
  return jsonb_build_object('id', v_id, 'code', c.code, 'action', v_action, 'agreement', a.status, 'wording', app.agreement_wording(b.id));
end $$;

-- What the "Edit the wording" panel reads: each clause with its rule, the change in force and the history.
create or replace function app.agreement_wording_state(p_by uuid, p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.user_is_staff(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return jsonb_build_object('is_admin', app.user_is_admin(p_by), 'wording', app.agreement_wording(p_booking),
    'clauses', (select jsonb_agg(jsonb_build_object('code', c.code, 'part', c.part, 'title', c.title, 'removable', c.removable, 'editable', c.editable) order by c.sort) from agreement_clauses c),
    'history', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'code', o.clause_code, 'action', o.action, 'text', o.text, 'reason', o.reason, 'at', o.created_at,
                                                           'by', (select u.full_name from users u where u.id = o.by_user)) order by o.created_at desc)
                           from booking_clause_overrides o where o.booking_id = p_booking), '[]'::jsonb));
end $$;

alter function app.agreement_state(uuid, uuid) rename to agreement_state_pre0198;
create or replace function app.agreement_state(p_by uuid, p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.agreement_state_pre0198(p_by, p_booking) || jsonb_build_object('wording', app.agreement_wording_state(p_by, p_booking))
$$;

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0198;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
  v_b uuid;
begin
  if p_call = 'ops_do' and p_name = 'agreement_wording_save' then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    v_b := coalesce((select id from bookings where id::text = p_ ->> 'booking' or booking_number = p_ ->> 'booking' limit 1), '00000000-0000-0000-0000-000000000000'::uuid);
    return app.agreement_wording_save(p_user, p_ || jsonb_build_object('booking', v_b));
  end if;
  return app.door_pre0198(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0198(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['agreement_wording', 'agreement_wording_save', 'agreement_wording_state', 'agreement_state', 'agreement_state_pre0198',
              'agreement_snapshot', 'agreement_snapshot_pre0198', 'agreement_key_label', 'agreement_key_label_pre0198', 'agreement_key_value', 'agreement_key_value_pre0198',
              'agreement_plan', 'agreement_plan_pre0198', 'door_pre0198', 'booking_clause_overrides_append_only']))
        or (n.nspname = 'public' and p.proname = 'server_agreement_wording')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
