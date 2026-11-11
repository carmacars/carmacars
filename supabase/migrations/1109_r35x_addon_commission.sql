-- 1109_r35x_addon_commission.sql
-- Release 35, UX batch (docs/changes/2026-11-09-r35-ux-batch.md). SCHEMA_MARKER 1110 (1110 follows).
-- The owner, November 9: "sales people should get the same commission rates on the add-ons too".
-- Since 0066 the commission base was the rental charge alone. It is now the rental charge plus the add-ons, at the
-- salesperson's same rate (the same tiers and rules, 0058, 0174): app.commission_addon_cents counts, for each add-on of
-- the booking that is confirmed (not removed, declined or cancelled), its own charge line before HST (booking_line_items,
-- not voided). Left out: prepaid fuel (a full tank is fuel resold at cost, a pass-through), and every other fee (delivery,
-- young driver, the Protection Plan ...), as before. Net of refunds like the rental part: an add-on removed after booking
-- leaves the count (its refund, reason addon_removed, was never in the rental part), a cancelled or refunded booking
-- earns nothing as before. staff_commissions.addon_base_cents is the add-on part of base_cents, for the breakdowns.
-- No applied migration is edited: app.commission_base_cents and app.commission_sync are wrapped (_pre1109).
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

alter table staff_commissions add column if not exists addon_base_cents bigint not null default 0 check (addon_base_cents >= 0);
comment on column staff_commissions.addon_base_cents is 'The add-on part of base_cents (1109): the confirmed add-ons'' charges before HST, prepaid fuel left out. The rest of base_cents is the rental charge.';

create or replace function app.commission_addon_cents(p_booking uuid) returns bigint
language sql stable security definer set search_path = public, app as $$
  select case when b.status::text in ('cancelled', 'no_show', 'expired', 'declined') then 0 else
    coalesce((select sum(greatest(li.amount_cents, 0))
                from booking_addons ba join addons a on a.id = ba.addon_id
                join booking_line_items li on li.id = ba.line_item_id and li.voided_at is null
               where ba.booking_id = b.id and ba.status = 'confirmed' and not a.prepaid_fuel), 0)::bigint end
    from bookings b where b.id = p_booking
$$;
comment on function app.commission_addon_cents(uuid) is 'Commission on add-ons (1109): the confirmed add-ons of a booking, each its charge line before HST; prepaid fuel left out; nothing on a cancelled booking.';

alter function app.commission_base_cents(uuid) rename to commission_base_cents_pre1109;
create function app.commission_base_cents(p_booking uuid) returns bigint
language plpgsql stable security definer set search_path = public, app as $$
declare
  v bigint := app.commission_base_cents_pre1109(p_booking);
begin
  -- a booking whose rental part is fully refunded earns nothing on its add-ons either
  if coalesce(v, 0) <= 0 then return coalesce(v, 0); end if;
  return v + coalesce(app.commission_addon_cents(p_booking), 0);
end $$;
select pg_temp.copy_grants('app.commission_base_cents(uuid)'::regprocedure, 'app.commission_base_cents_pre1109(uuid)'::regprocedure);

alter function app.commission_sync(uuid) rename to commission_sync_pre1109;
create function app.commission_sync(p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.commission_sync_pre1109(p_booking);
  update staff_commissions c
     set addon_base_cents = least(case when c.base_cents > 0 then coalesce(app.commission_addon_cents(p_booking), 0) else 0 end, greatest(c.base_cents, 0))
   where c.booking_id = p_booking and c.kind = 'commission' and c.status in ('accruing', 'pending_approval', 'approved')
     and c.addon_base_cents is distinct from least(case when c.base_cents > 0 then coalesce(app.commission_addon_cents(p_booking), 0) else 0 end, greatest(c.base_cents, 0));
end $$;
select pg_temp.copy_grants('app.commission_sync(uuid)'::regprocedure, 'app.commission_sync_pre1109(uuid)'::regprocedure);

-- an add-on confirmed, removed or declined after booking moves the commission
drop trigger if exists booking_addons_commission_sync on booking_addons;
create trigger booking_addons_commission_sync after insert or update of status, line_item_id on booking_addons
  for each row execute function app.commission_sync_trigger();

-- the commissions not yet paid: their base with the add-ons now
do $$
declare r record;
begin
  for r in select distinct c.booking_id from staff_commissions c
            where c.kind = 'commission' and c.status in ('accruing', 'pending_approval')
              and exists (select 1 from booking_addons ba where ba.booking_id = c.booking_id and ba.status = 'confirmed') loop
    begin
      perform app.commission_sync(r.booking_id);
    exception when others then
      raise warning 'commission on add-ons not synced for %: %', r.booking_id, sqlerrm;
    end;
  end loop;
end $$;

-- the commission lists (Sales' own, the Admin's) carry the add-on part beside the base
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.prokind = 'f' and pg_get_functiondef(p.oid) like '%''base_cents'', c.base_cents,%'
              and pg_get_functiondef(p.oid) like '%staff_commissions c %' and pg_get_functiondef(p.oid) not like '%addon_base_cents%'
  loop
    execute replace(pg_get_functiondef(f.sig), '''base_cents'', c.base_cents,', '''base_cents'', c.base_cents, ''addon_base_cents'', c.addon_base_cents,');
  end loop;
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['commission_addon_cents', 'commission_base_cents_pre1109', 'commission_sync_pre1109'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
