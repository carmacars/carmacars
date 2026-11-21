-- 3272 (release 48, part RW; docs/changes/2026-11-20-r48-rewards-calendar-notify.md): the booking's Money tab shows the
-- owner-use charges of an Owner Booking (3270): the charges waiting for their evidence, and each owner invoice they were
-- billed on with how it is being collected (card, bank debit, pay link, or the next statement) and when it would be
-- deducted. app.booking_money is wrapped (as 3053 did for the tips); the read itself is app.owner_use_charges_read.
-- Every portal that opens a booking's Money tab (Admin, Finance, Sales, Operations) gets it, since they share the read.
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

alter function app.booking_money(uuid, jsonb) rename to booking_money_pre3272;
create function app.booking_money(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := app.booking_money_pre3272(p_by, p);
  v_b uuid;
begin
  if v is null or nullif(v ->> 'booking_id', '') is null then return v; end if;
  v_b := (v ->> 'booking_id')::uuid;
  if not exists (select 1 from bookings b where b.id = v_b and b.booking_type::text = 'owner') then return v; end if;
  return v || jsonb_build_object('owner_use', app.owner_use_charges_read(v_b));
end $$;
select pg_temp.copy_grants('app.booking_money(uuid, jsonb)'::regprocedure, 'app.booking_money_pre3272(uuid, jsonb)'::regprocedure);
comment on function app.booking_money(uuid, jsonb) is 'The booking''s Money tab (0213 on); 3053 adds the tips; 3272 adds owner_use (app.owner_use_charges_read) on an Owner Booking.';
