-- 5133 (R50 hotfix 2, Sales; docs/changes/2026-11-27-r50-sales-fixes.md). Two owner reports of Nov 27.
--
-- 1. "When accepting a request, salesperson Jamal is missing from the list." The people an Admin gives a booking's sale or an
--    extension to come from app.sales_staff_options (0057/0058/0440): each with one function word, the profile's
--    va_function, else 'field', else 'admin'. A field staff member who added Sales (0931, "I want to do sales too": staff_type
--    field, functions {field, sales}, no va_function) was listed as 'field', and the extension's "Give to" list keeps only
--    'sales' (BookingPage's salespeople), so they never showed; the Reassign list called them Field. Jamal is such a person.
--    Now the function word is 'sales' for everyone who holds the Sales function (app.user_va_has_sales: active, the va
--    role, the function), whatever their staff type, onboarding step or inactivity warning; and each option carries
--    `functions` and `sales`. Nothing else about who is listed changes (every active staff member who may earn sales credit,
--    2330's credit_blocked and test accounts left out).
-- 2. Commission on an extension (the Tibirica case, CC-10131: Admin handled the extension and the weekly payments, and the
--    booking's salesperson still earned on them). 3101 gave every new extension to the booking's salesperson by default.
--    Now an extension goes to the person who started it: a salesperson who asked for it (requested_by, or the staff member
--    whose session made it) handles it and earns on it; one the renter asked for, a weekly payment made by the rolling job,
--    or one an Admin or customer service started goes to Admin (handled_queue admin: no commission, 3101). An Admin can
--    still give it to a salesperson (extension_assign, with the reason). The extensions already made by default this way
--    and recorded as started by someone else move to Admin too (none whose starter is not recorded), unless that
--    salesperson's commission on the booking is approved or paid (then an Admin decides with Give to); each move is in the
--    audit log and the commission is synced. Every new extension records who started it (requested_by: the caller, else
--    the signed-in session).
-- SCHEMA_MARKER is not changed. No applied migration is edited: app.sales_staff_options and app.extension_default_handler
-- are replaced.
set local check_function_bodies = off;

-- ================================================================ 1. the people listed
create or replace function app.sales_staff_options(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  perform app.assert_admin(p_by);
  return coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'name', coalesce(u.full_name, u.email),
                     'function', case when app.user_va_has_sales(u.id) then 'sales'
                                      else coalesce(sp.va_function::text, case when 'field' = any (sp.functions) then 'field' end, 'admin') end,
                     'sales', app.user_va_has_sales(u.id), 'functions', to_jsonb(coalesce(sp.functions, '{}'::text[])))
                     order by coalesce(u.full_name, u.email))
                     from users u left join staff_profiles sp on sp.user_id = u.id
                    where app.user_is_sales_staff(u.id) and not app.credit_blocked(u.id) and not u.is_test), '[]'::jsonb);
end $$;

-- ================================================================ 2. who handles a new extension: who started it
create or replace function app.extension_default_handler() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v_by uuid;
begin
  -- every path records who started it: the caller's own, else the signed-in session's (null: a job)
  new.requested_by := coalesce(new.requested_by, nullif(current_setting('request.jwt.claim.sub', true), '')::uuid);
  if new.handled_by is null and new.handled_queue = 'sales' then
    v_by := new.requested_by;
    if v_by is not null and app.user_va_has_sales(v_by) and not app.user_is_admin(v_by) then
      new.handled_by := v_by;
    else
      new.handled_by := null;
      new.handled_queue := 'admin';
    end if;
  end if;
  return new;
exception when invalid_text_representation then
  new.requested_by := null; new.handled_by := null; new.handled_queue := 'admin';
  return new;
end $$;

-- the extensions given by default to the booking's salesperson when someone else is recorded as starting them (one with
-- no requested_by is left as it is: who started it is not known)
create or replace function app.extension_credit_backfill() returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  r record;
  n integer := 0;
  v_bookings uuid[] := '{}';
  v_b uuid;
begin
  for r in select e.id, e.booking_id, e.handled_by, e.handled_queue
             from booking_extensions e join bookings b on b.id = e.booking_id
            where e.handled_queue = 'sales' and e.handled_set_by is null and e.handled_by is not null
              and e.handled_by = b.sales_staff_id and e.requested_by is not null and e.requested_by <> e.handled_by
              and e.status not in ('declined', 'lapsed', 'cancelled')
              and not exists (select 1 from staff_commissions c where c.booking_id = e.booking_id and c.staff_id = e.handled_by
                                and c.kind = 'commission' and c.status in ('approved', 'paid'))
            order by e.booking_id, e.seq loop
    update booking_extensions set handled_by = null, handled_queue = 'admin', handled_set_at = now(),
           handled_reason = '5133: started by someone else (the renter or Admin): no commission'
     where id = r.id;
    insert into audit_log (action, entity_table, entity_id, before, after)
    values ('extension_assign', 'booking_extensions', r.id::text, jsonb_build_object('handled_by', r.handled_by, 'handled_queue', r.handled_queue),
            jsonb_build_object('handled_by', null, 'handled_queue', 'admin', 'reason', '5133: started by someone else'));
    n := n + 1;
    if not r.booking_id = any (v_bookings) then v_bookings := v_bookings || r.booking_id; end if;
  end loop;
  foreach v_b in array v_bookings loop
    perform app.commission_sync(v_b);
  end loop;
  return n;
end $$;
select app.extension_credit_backfill();

revoke all on function app.sales_staff_options(uuid), app.extension_default_handler(), app.extension_credit_backfill() from public, anon, authenticated;
grant execute on function app.sales_staff_options(uuid), app.extension_default_handler(), app.extension_credit_backfill() to service_role;
