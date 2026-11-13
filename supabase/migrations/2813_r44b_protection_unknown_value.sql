-- 2813 (release 44, part B): the Protection Plan is offered on a car with no value on file, by default and everywhere.
--   1. Program settings rentalcover_unknown_value_allowed is on by default (it was turned on in production): a car with no
--      value on file is offered the plan, priced as any car is (a RentalCover quote when the partner key is set, else, or
--      when a quote cannot be had, the Protection Plan's own price from Settings > Fees). A new install starts so; an
--      install that has it off keeps it off.
--   2. Every path that offers the plan asks the same rule (app.rentalcover_allowed): the request and the offer (the
--      quote, 1202), the booking's own guard (1202), and now the protection change on a booking, staff's switch and the
--      renter's request in their portal (app.protection_block, 2540): a car the plan is not offered for says why at once,
--      instead of the save failing on the booking's guard.
--   3. Data Health's "Car value missing" says what the setting means: with it on, the plan is offered and the value is
--      still worth entering (the RentalCover cap); with it off, the plan is not offered.
-- No applied migration is edited: function bodies are patched in place, or wrapped.

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '2813: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;
create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. the default
alter table program_settings alter column rentalcover_unknown_value_allowed set default true;
-- a fresh install (no settings row changed by a person yet: only the seeded row) starts with it on
update program_settings set rentalcover_unknown_value_allowed = true
 where not rentalcover_unknown_value_allowed and (select count(*) from program_settings) = 1 and created_by is null;
select set_config('app.settings_gen', gen_random_uuid()::text, true);
comment on column program_settings.rentalcover_unknown_value_allowed is 'RentalCover (1202; on by default since 2813): offer the Protection Plan on a car with no value on file, priced as any car. Off: unknown counts as over the cap.';

-- ================================================================ 2. the protection change asks the same rule
select pg_temp.patch_fn('app.protection_block(bookings, integer, text)'::regprocedure,
  'if not app.protection_plan_priced(b.id) then',
  'if not app.rentalcover_allowed(b.vehicle_id) then
      return app.rentalcover_check(b.vehicle_id) ->> ''reason'';
    end if;
    if not app.protection_plan_priced(b.id) then');

-- ================================================================ 3. Data Health's wording
alter function app.data_health(timestamptz) rename to data_health_pre2813;
create function app.data_health(p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r jsonb := app.data_health_pre2813(p_now);
begin
  if not coalesce((app.settings()).rentalcover_unknown_value_allowed, true) then return r; end if;
  return jsonb_set(r, '{checks}', coalesce((select jsonb_agg(case when c ->> 'key' = 'car_value_missing'
      then c || jsonb_build_object('line', 'Cars with no value on file: the Protection Plan is offered for them, but enter the value so a car worth $50,000 or more (RentalCover''s cap) is not offered it',
                                   'items', coalesce((select jsonb_agg(i || jsonb_build_object('text', replace(i ->> 'text', 'so the Protection Plan (RentalCover) is not offered for it', 'the Protection Plan is offered without the RentalCover cap check')))
                                                        from jsonb_array_elements(c -> 'items') i), '[]'::jsonb))
      else c end order by o) from jsonb_array_elements(r -> 'checks') with ordinality x(c, o)), '[]'::jsonb));
end $$;
select pg_temp.copy_grants('app.data_health(timestamptz)'::regprocedure, 'app.data_health_pre2813(timestamptz)'::regprocedure);
revoke all on function app.data_health_pre2813(timestamptz) from public, anon, authenticated;
grant execute on function app.data_health_pre2813(timestamptz) to service_role;
