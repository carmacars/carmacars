-- 1106_r35x_sales_get_ready.sql
-- Release 35, UX batch (docs/changes/2026-11-09-r35-ux-batch.md). SCHEMA_MARKER 1109 (1107 to 1109 follow).
-- The owner, November 9: "sales people should be able to request payment, edit offers, and verify id and basically do
-- everything to make sure a renter is good to go for a rental."
-- Sales already sent pay links (payreq_create, 0129 and 0970's card_collect_allowed), regenerated the agreement and
-- reviewed the licence (0169). What stopped them was the stage: Sales worked on requests and offers only, so a booking
-- waiting for payment or confirmed (not yet handed over) was closed to them, and the proof of coverage was customer
-- service's. A Sales person now does customer service's get-ready work for one call at a time, on a booking that is not
-- yet handed over:
--   reads:   the booking (its payments without processor ids; no refunds, statements or emails), its conversation and
--            its activity log;
--   offers:  save, send, send again with a later expiry, withdraw, approved by phone, ask the renter, revise in place
--            (requested, offered, pending_payment, tentative);
--   ID:      approve or reject the licence, the selfie and the proof of coverage, with the reason (doc_review_upload,
--            verify_upload), confirmed bookings included.
-- Nothing that moves money out: refunds (removing a paid add-on after booking is refused to Sales too), cancellations, deposit releases or settlements, payouts, fee changes and voids
-- stay where they were (none of them is in the list below). It is 0169's way: the Sales person acts as customer service
-- for that call only (app.field_as_cs and app.sales_as_cs, cleared at once), the history names Sales (app.review_role),
-- and every row the call writes is audited as before with the Sales person as the actor.
-- No applied migration is edited: app.door, app.va_fn and app.va_active_fn are wrapped (_pre1106).
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

-- the calls a Sales person makes as customer service, and the stages each is open on. A request and an offer stay under
-- Sales' own rules (0177's claims: customer service has a request first), so they are not listed: only the stages after it.
create or replace function app.sales_ready_stages(p_call text, p_name text) returns text[]
language sql immutable as $$
  select case
    when p_call = 'va_read' and p_name = 'booking' then array['pending_payment', 'tentative', 'confirmed']
    when p_call = 'ops_read' and p_name in ('booking_conversation', 'renter_activity') then array['pending_payment', 'tentative', 'confirmed']
    when p_call = 'va_do' and p_name in ('booking_save', 'send_offer', 'resend_offer', 'withdraw_offer', 'approve_offer_by_phone', 'ask_info')
      then array['pending_payment', 'tentative']
    when p_call = 'ops_do' and p_name = 'offer_revise' then array['pending_payment', 'tentative']
    when (p_call = 'va_do' and p_name = 'verify_upload') or (p_call = 'ops_do' and p_name = 'doc_review_upload')
      then array['pending_payment', 'tentative', 'confirmed']
  end
$$;
comment on function app.sales_ready_stages(text, text) is 'Sales get-ready work (1106): the staff calls a Sales person makes as customer service, and the booking stages each is open on. Nothing that moves money out is listed.';

-- a Sales person (not customer service, not an Admin) working as Sales
create or replace function app.sales_ready_user(p_user uuid, p jsonb) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is not null and app.user_va_has(p_user, 'sales') and not app.user_va_has(p_user, 'cs') and not app.user_is_admin(p_user)
     and coalesce(nullif(p ->> '_va', ''), 'sales') = 'sales'
$$;

create or replace function app.sales_ready_booking(p jsonb) returns bookings
language sql stable security definer set search_path = public, app as $$
  select b.* from bookings b
   where b.id::text = coalesce(p ->> 'booking', p ->> 'booking_id', '')
      or b.booking_number = upper(btrim(coalesce(p ->> 'booking', p ->> 'number', '')))
      or b.id = (select u.booking_id from verification_uploads u where u.id::text = coalesce(p ->> 'upload', ''))
   limit 1
$$;

-- customer service's function for this call: va_fn answers cs while the Sales person's call runs
alter function app.va_fn(uuid) rename to va_fn_pre1106;
create function app.va_fn(p_user uuid) returns text
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_user is not null and coalesce(current_setting('app.sales_as_cs', true), '') = p_user::text then return 'cs'; end if;
  return app.va_fn_pre1106(p_user);
end $$;
select pg_temp.copy_grants('app.va_fn(uuid)'::regprocedure, 'app.va_fn_pre1106(uuid)'::regprocedure);
alter function app.va_active_fn(uuid) rename to va_active_fn_pre1106;
create function app.va_active_fn(p_user uuid) returns text
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_user is not null and coalesce(current_setting('app.sales_as_cs', true), '') = p_user::text then return 'cs'; end if;
  return app.va_active_fn_pre1106(p_user);
end $$;
select pg_temp.copy_grants('app.va_active_fn(uuid)'::regprocedure, 'app.va_active_fn_pre1106(uuid)'::regprocedure);

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre1106;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_stages text[] := app.sales_ready_stages(p_call, p_name);
  b bookings;
  v jsonb;
begin
  -- removing an add-on after booking refunds a paid one: customer service or an Admin, never Sales alone
  if p_call = 'ops_do' and p_name = 'booking_addon_remove' and app.sales_ready_user(p_user, coalesce(p, '{}'::jsonb)) then
    raise exception 'Customer service or an Admin removes an add-on after booking (a paid one is refunded)' using errcode = '42501';
  end if;
  if v_stages is not null and app.sales_ready_user(p_user, coalesce(p, '{}'::jsonb)) then
    b := app.sales_ready_booking(coalesce(p, '{}'::jsonb));
    if b.id is not null and b.status::text = any (v_stages) and b.handed_over_at is null and b.booking_type <> 'owner' then
      perform set_config('app.field_as_cs', p_user::text, true);
      perform set_config('app.sales_as_cs', p_user::text, true);
      perform set_config('app.review_role', 'sales', true);
      v := app.door_pre1106(p_user, p_aal, p_call, p_name, (coalesce(p, '{}'::jsonb) - '_va') || jsonb_build_object('_va', 'cs'));
      perform set_config('app.field_as_cs', '', true);
      perform set_config('app.sales_as_cs', '', true);
      perform set_config('app.review_role', '', true);
      if p_call = 'va_read' and p_name = 'booking' and jsonb_typeof(v) = 'object' then
        v := v - 'refunds' - 'statements' - 'emails' || jsonb_build_object('va_function', 'sales', 'sales_get_ready', true);
      end if;
      return v;
    end if;
  end if;
  return app.door_pre1106(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre1106(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['sales_ready_stages', 'sales_ready_user', 'sales_ready_booking', 'door_pre1106', 'va_fn_pre1106', 'va_active_fn_pre1106'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
