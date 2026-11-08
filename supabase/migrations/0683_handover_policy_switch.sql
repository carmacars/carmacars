-- 0683_handover_policy_switch.sql
-- Hotfix (owner, Nov 7 2026): the insurer gate of 0078 (app.booking_handover_on_policy) refused every pickup of a car
-- not yet marked "Insurer confirmed", while the company works with its insurer on the newer cars. It is now a Program
-- setting, Settings > Program > Field jobs and handovers, OFF by default: when off, a car not on the fleet policy is
-- handed over like any other (requests and offers still show the "not on the fleet policy yet" warning); when on, the
-- 0078 rule applies unchanged. The same setting covers staff adding a rental by hand for such a car (0064, 0072:
-- only an Admin, with a tick): off, anyone who adds rentals adds it like any other.
-- SCHEMA_MARKER 0683. No applied migration is edited.

alter table program_settings add column if not exists field_handover_requires_fleet_policy boolean not null default false;
comment on column program_settings.field_handover_requires_fleet_policy is 'When on, a car not on the fleet insurance policy (Insurer confirmed not pressed) cannot be handed over (0078). Off by default since 0683.';

create or replace function app.booking_handover_on_policy() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = 'on_rent' and old.status is distinct from 'on_rent'
     and coalesce((app.settings()).field_handover_requires_fleet_policy, false)
     and not app.vehicle_on_policy(new.vehicle_id) then
    raise exception 'This car is not on the fleet insurance policy yet: it cannot be handed over. When the insurer confirms it in writing, press Insurer confirmed on the car (or on Admin > Today), or move the booking to another car'
      using errcode = '23514';
  end if;
  return new;
end $$;

-- the rental added by hand (0064): the Admin-only rule and its tick follow the same setting
create or replace function app.vehicle_needs_policy_confirm(p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((app.settings()).field_handover_requires_fleet_policy, false)
     and coalesce((select v.supply_type = 'program_owner' and not coalesce(v.on_fleet_policy, false) and not app.vehicle_listing_finished(v.id)
                     from vehicles v where v.id = p_vehicle), false)
$$;
