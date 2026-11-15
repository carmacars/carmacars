-- Release 48 (the owner: "When editing an offer, I shouldn't need to withdraw it first"). The fees of an offer that is out
-- (offered, or approved and not paid) are changed in place from the booking's Money tab, as the offer screen (offer_revise)
-- and the coverage switch (0890) already do: the offer is opened for the edit, the fee is changed, and the next version
-- goes out to the renter (by email unless notify is false). Before, the Fees card said "The offer and the price follow"
-- and the database refused with "An offer has been sent: withdraw it (back to requested) before changing its terms".
-- Inside an offer edit (app.offer_revising on, as offer_revise calls these) nothing changes: the edit sends once.
-- No applied migration is edited: booking_fees_change and booking_custom_fee are wrapped (_pre2940).

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- an offer that is out, about to have its terms changed outside an offer edit: opened for the edit (its status is then
-- requested); returns the status it had, or null when there is nothing to do
create function app.offer_edit_begin(p jsonb, p_by uuid) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
begin
  if coalesce(current_setting('app.offer_revising', true), '') = 'on' then return null; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null or b.status::text not in ('offered', 'pending_payment') or b.current_offer_version is null then return null; end if;
  perform set_config('app.offer_revising', 'on', true);
  return app.offer_reopen_for_edit(b.id, p_by);
end $$;

-- the edit done: the next version goes out (the renter told unless notify is false), keeping the offer's expiry when it
-- has more than an hour left
create function app.offer_edit_end(p jsonb, p_by uuid, p_what text) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v integer;
begin
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', '')));
  perform app.offer_channels_begin(coalesce((p ->> 'notify')::boolean, true), p -> 'channels');
  v := app.send_offer(b.id, p_by, p_what,
         case when b.offer_expires_at > now() + interval '1 hour' then b.offer_expires_at else now() + make_interval(hours => (app.settings()).offer_expiry_hours) end);
  perform app.offer_channels_end();
  perform set_config('app.offer_revising', '', true);
  return v;
end $$;
revoke all on function app.offer_edit_begin(jsonb, uuid) from public, anon, authenticated;
revoke all on function app.offer_edit_end(jsonb, uuid, text) from public, anon, authenticated;
grant execute on function app.offer_edit_begin(jsonb, uuid) to service_role;
grant execute on function app.offer_edit_end(jsonb, uuid, text) to service_role;

alter function app.booking_fees_change(uuid, jsonb) rename to booking_fees_change_pre2940;
create function app.booking_fees_change(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_was text := app.offer_edit_begin(p, p_by);
  r jsonb;
begin
  r := app.booking_fees_change_pre2940(p_by, p);
  if v_was is null then return r; end if;
  return r || jsonb_build_object('offer_version', app.offer_edit_end(p, p_by, 'We changed a fee on your offer: please check the new total.'), 'status', 'offered');
end $$;
select pg_temp.copy_grants('app.booking_fees_change(uuid, jsonb)'::regprocedure, 'app.booking_fees_change_pre2940(uuid, jsonb)'::regprocedure);

alter function app.booking_custom_fee(uuid, jsonb) rename to booking_custom_fee_pre2940;
create function app.booking_custom_fee(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_was text;
  r jsonb;
begin
  -- who may add a charge is checked first (the wrapped function), never after the offer was opened
  if not app.may_edit_fees(p_by) then return app.booking_custom_fee_pre2940(p_by, p); end if;
  v_was := app.offer_edit_begin(p, p_by);
  r := app.booking_custom_fee_pre2940(p_by, p);
  if v_was is null then return r; end if;
  return r || jsonb_build_object('offer_version', app.offer_edit_end(p, p_by, 'We added a charge to your offer: please check the new total.'), 'status', 'offered');
end $$;
select pg_temp.copy_grants('app.booking_custom_fee(uuid, jsonb)'::regprocedure, 'app.booking_custom_fee_pre2940(uuid, jsonb)'::regprocedure);

comment on function app.offer_edit_begin(jsonb, uuid) is 'Release 48 (2940): an offer that is out opened for a fee change from the Money tab (no withdraw first); app.offer_edit_end sends the next version.';
