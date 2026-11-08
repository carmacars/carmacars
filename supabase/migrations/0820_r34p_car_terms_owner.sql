-- 0820: a car's terms belong to its current owner (Release 34, part P; docs/changes/2026-11-08-r34-owner-onboarding.md).
-- SCHEMA_MARKER 0839 for the part. No applied migration is edited.
--
-- The bug: on an owner's Terms tab, a car moved from company supply to the owner (vehicle_set_supply) was edited, Review
-- and Save said "Saved", and the row kept the old amounts after a reload. The car's negotiated terms (owner_terms with a
-- vehicle_id) are kept per owner and car (the exclusion constraint is on owner_id, vehicle_id and the dates), but they
-- were read by the car alone: app.owner_terms_resolve took "the" car row covering the date with no owner and no order.
-- After the move the company's (or the earlier owner's) row still covered today next to the new owner's row; the read
-- returned the first by owner id, here the old one. So the Save wrote the new owner's row, then filled the car's
-- unsigned Vehicle Schedule (which the Terms row shows) from the old one: $300 / $25 / $100 again.
--
-- The fix:
--   1. app.owner_terms_resolve reads the car row of the car's current owner only (patched in place).
--   2. A car that changes owner closes the other owners' car rows from today (vehicles_owner_terms_retire, after an
--      update of owner_id): a row that started before today ends today, a later one is removed. Audited.
--   3. Once for the cars that exist: the same, and a car whose unsigned Vehicle Schedule was filled from another
--      owner's row is filled again from its own owner's terms (the numbers the Admin saved).
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '0820: the text to change was not found in %: %', p_sig, left(p_old, 120); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the read: the current owner's car row
select pg_temp.patch_fn('app.owner_terms_resolve(uuid, date, uuid, management_mode)'::regprocedure,
  'select * into vt from owner_terms x where x.vehicle_id = p_vehicle and x.effective_from <= v_on',
  'select * into vt from owner_terms x where x.vehicle_id = p_vehicle and x.owner_id = v_owner and x.effective_from <= v_on');

-- ================================================================ 2. a car that changes owner
create function app.owner_terms_retire(p_vehicle uuid, p_by uuid default null) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  v_today date := app.today();
  n integer := 0;
  k integer;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then return 0; end if;
  delete from owner_terms t where t.vehicle_id = v.id and t.owner_id <> v.owner_id and t.effective_from >= v_today;
  get diagnostics k = row_count; n := n + k;
  update owner_terms t set effective_to = v_today
   where t.vehicle_id = v.id and t.owner_id <> v.owner_id and t.effective_from < v_today and (t.effective_to is null or t.effective_to > v_today);
  get diagnostics k = row_count; n := n + k;
  if n > 0 then
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'owner_terms_retire', 'vehicles', v.id::text, jsonb_build_object('owner_id', v.owner_id, 'rows', n, 'from', v_today));
  end if;
  return n;
end $$;

create function app.vehicles_owner_terms_retire() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.owner_terms_retire(new.id, nullif(current_setting('request.jwt.claim.sub', true), '')::uuid);
  return null;
exception when invalid_text_representation then
  perform app.owner_terms_retire(new.id, null);
  return null;
end $$;
create trigger vehicles_owner_terms_retire after update of owner_id on vehicles
  for each row when (old.owner_id is distinct from new.owner_id) execute function app.vehicles_owner_terms_retire();

-- ================================================================ 3. the cars that exist
do $$
declare
  r record;
  s vehicle_schedules;
  res jsonb;
begin
  for r in select distinct t.vehicle_id from owner_terms t join vehicles v on v.id = t.vehicle_id
            where t.owner_id <> v.owner_id and (t.effective_to is null or t.effective_to > app.today()) loop
    perform app.owner_terms_retire(r.vehicle_id, null);
    select * into s from vehicle_schedules x where x.vehicle_id = r.vehicle_id and x.superseded_by is null;
    -- an unsigned schedule of a car that has its own owner's terms: written from them again (0067's owner_terms_save)
    if s.id is not null and s.signed_at is null
       and exists (select 1 from owner_terms t join vehicles v on v.id = t.vehicle_id where t.vehicle_id = r.vehicle_id and t.owner_id = v.owner_id
                     and t.effective_from <= app.today() and (t.effective_to is null or t.effective_to > app.today())) then
      res := app.owner_terms_resolve(r.vehicle_id);
      if (s.insurance_fee_cents, s.tracker_fee_cents, s.revenue_share_bps, s.install_fee_cents)
         is distinct from ((res ->> 'insurance_fee_cents')::bigint, (res ->> 'tracker_fee_cents')::bigint, (res ->> 'revenue_share_bps')::integer, (res ->> 'install_fee_cents')::bigint)
         and not (s.management_mode = 'self_managed' and (res ->> 'revenue_share_bps')::integer <> 0) then
        update vehicle_schedules set insurance_fee_cents = (res ->> 'insurance_fee_cents')::bigint, tracker_fee_cents = (res ->> 'tracker_fee_cents')::bigint,
               revenue_share_bps = (res ->> 'revenue_share_bps')::integer, install_fee_cents = (res ->> 'install_fee_cents')::bigint
         where id = s.id;
        insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
        values (null, 'owner_terms_schedule_fix', 'vehicle_schedules', s.id::text, jsonb_build_object('schedule_number', s.schedule_number,
                'insurance_fee_cents', res -> 'insurance_fee_cents', 'tracker_fee_cents', res -> 'tracker_fee_cents', 'revenue_share_bps', res -> 'revenue_share_bps',
                'install_fee_cents', res -> 'install_fee_cents'));
      end if;
    end if;
  end loop;
end $$;

revoke all on function app.owner_terms_retire(uuid, uuid) from public, anon, authenticated;
revoke all on function app.vehicles_owner_terms_retire() from public, anon, authenticated;
