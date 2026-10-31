-- 0239: the Tracker Fee and the Tracker Install Fee only once a tracker is installed on the car
-- (docs/changes/2026-11-03-tracker-fee-from-install.md). The owner, Release 23: CarmaCars' trackers are not ready yet.
--
-- 1. The monthly owner invoice (app.generate_owner_invoice, 0029 and 0196) charged the Tracker Fee to every car not marked
--    "waiting for a tracker" (vehicles.tracker_install_pending), from the enrolment, even with no installation recorded.
--    Now it runs only from the installation (vehicles.tracker_installed_on, recorded by app.record_tracker_installed):
--    none before, the first month prorated from the install date, as 0029 already did for an installation mid-month.
-- 2. The Tracker Install invoice (oi_plan_invoice 'tracker_install') is made only for a car with its installation recorded.
-- 3. app.tracker_fee_audit(): the Tracker Fee and Tracker Install Fee charged so far to cars with no installation
--    recorded (owners, cars, invoices, amount): Admin reads it (admin_read tracker_fee_audit) to credit what was charged.
--    Nothing already invoiced is changed by this migration.
-- No applied migration is edited.

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0239: the text to change was not found in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

select pg_temp.patch_fn('app.generate_owner_invoice_0029(uuid, date, uuid)'::regprocedure,
  $o$  v_trk_line := not v.tracker_install_pending;$o$,
  $n$  v_trk_line := not v.tracker_install_pending and v.tracker_installed_on is not null;$n$);
select pg_temp.patch_fn('app.generate_owner_invoice_0029(uuid, date, uuid)'::regprocedure,
  $o$  if v.tracker_install_pending or (v.tracker_installed_on is not null and v.tracker_installed_on >= (v_month + interval '1 month')::date) then$o$,
  $n$  if v.tracker_install_pending or v.tracker_installed_on is null or v.tracker_installed_on >= (v_month + interval '1 month')::date then$n$);
select pg_temp.patch_fn('app.generate_owner_invoice_pre0196(uuid, date, uuid)'::regprocedure,
  $o$  v_trk_start := case when v.tracker_installed_on is not null and v.tracker_installed_on > v_start then v.tracker_installed_on else v_start end;$o$,
  $n$  -- 0239: no Tracker Fee before the installation is recorded
  v_trk_start := case when v.tracker_installed_on is null then v_end + 1 when v.tracker_installed_on > v_start then v.tracker_installed_on else v_start end;$n$);
select pg_temp.patch_fn('app.oi_plan_invoice(uuid, uuid, jsonb, jsonb, uuid)'::regprocedure,
  $o$    v_kind := 'tracker_install';$o$,
  $n$    if (select tracker_installed_on from vehicles where id = p_vehicle) is null then
      raise exception 'Record the tracker installation on the car first: the Tracker Install Fee is billed once it is installed' using errcode = '23514';
    end if;
    v_kind := 'tracker_install';$n$);

create or replace function app.tracker_fee_audit(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return (with x as (
    select i.owner_id, i.vehicle_id, i.id as invoice_id, i.invoice_number, i.status, l.kind, l.amount_cents + l.hst_cents as cents
      from owner_invoice_lines l join owner_invoices i on i.id = l.owner_invoice_id join vehicles v on v.id = i.vehicle_id
     where l.kind in ('tracker_fee', 'install_fee') and l.amount_cents > 0 and i.status <> 'void'
       and (v.tracker_installed_on is null or (l.kind = 'tracker_fee' and i.period_month is not null and v.tracker_installed_on > (i.period_month + interval '1 month - 1 day')::date)))
  select jsonb_build_object('owners', (select count(distinct owner_id) from x), 'cars', (select count(distinct vehicle_id) from x),
           'invoices', (select count(distinct invoice_id) from x), 'charged_cents', coalesce((select sum(cents) from x), 0),
           'paid_or_issued_cents', coalesce((select sum(cents) from x where status not in ('draft')), 0),
           'rows', coalesce((select jsonb_agg(jsonb_build_object('invoice_number', invoice_number, 'status', status, 'kind', kind, 'cents', cents,
                     'vehicle', app.vehicle_name(vehicle_id)) order by invoice_number) from x), '[]'::jsonb)));
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0239;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_read' and p_name = 'tracker_fee_audit' then
    perform app.door_begin(p_user, p_aal);
    return app.tracker_fee_audit(p_user);
  end if;
  return app.door_pre0239(p_user, p_aal, p_call, p_name, p);
end $$;
do $$
declare g text;
begin
  execute 'revoke all on function app.door(uuid, text, text, text, jsonb) from public, anon, authenticated';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.door_pre0239(uuid, text, text, text, jsonb)'::regprocedure, 'execute') then
      execute format('grant execute on function app.door(uuid, text, text, text, jsonb) to %I', g);
    end if;
  end loop;
  execute 'revoke all on function app.tracker_fee_audit(uuid) from public, anon, authenticated';
  execute 'grant execute on function app.tracker_fee_audit(uuid) to service_role';
  execute 'revoke all on function app.door_pre0239(uuid, text, text, text, jsonb) from public, anon, authenticated';
  execute 'grant execute on function app.door_pre0239(uuid, text, text, text, jsonb) to service_role';
end $$;
