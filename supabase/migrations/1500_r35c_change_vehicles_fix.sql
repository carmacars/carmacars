-- 1500_r35c_change_vehicles_fix.sql
-- Release 35, part C (item 7): the car-change list of a booking (ops40 'change_vehicles') failed with "column reference
-- b.id is ambiguous": the query's alias b clashed with the function's own variable b (a bookings row), so the list was
-- always empty. The same function again with the booking read first into the variable and no clashing alias.
-- No applied migration is edited: app.ops40 is replaced (its other branches are unchanged).
set local check_function_bodies = off;

create or replace function app.ops40(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  b bookings;
begin
  if not app.user_is_staff(p_user) then raise exception 'Not permitted' using errcode = '42501'; end if;
  case p_name
  when 'change_preview' then return app.propose_preview(p_user, p_);
  when 'change_vehicles' then
    -- the cars a booking may move to: open for bookings (0024's rule), with the booking's own car first
    -- 1500: the booking is read into the variable first; the query no longer has an alias b of its own
    select * into b from bookings x where x.id::text = p_ ->> 'booking' or x.booking_number = p_ ->> 'booking' limit 1;
    return coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate, 'owner', o.legal_name)
                                      order by (v.id is not distinct from b.vehicle_id) desc, app.vehicle_name(v.id))
                       from vehicles v join owners o on o.id = v.owner_id
                      where v.status in ('available', 'on_rent', 'cleaning') and coalesce(app.vehicle_bookable(v.id), false)), '[]'::jsonb);
  when 'change_propose' then return app.propose_booking_change(p_user, p_);
  when 'change_withdraw' then
    if not (app.user_is_admin(p_user) or app.user_va_has(p_user, 'cs', 'fleet')) then raise exception 'Not permitted' using errcode = '42501'; end if;
    perform app.withdraw_booking_change((p_ ->> 'request')::uuid, p_user);
    return jsonb_build_object('request', p_ ->> 'request', 'status', 'cancelled');
  when 'turnaround_block_remove' then return app.remove_turnaround_block(p_user, (p_ ->> 'block')::uuid, p_ ->> 'reason');
  when 'vehicle_turnaround' then return app.set_vehicle_turnaround(p_user, (p_ ->> 'vehicle')::uuid, nullif(p_ ->> 'minutes', '')::integer);
  when 'similarity_decide' then return app.decide_similarity(p_user, (p_ ->> 'flag')::uuid, p_ ->> 'decision', p_ ->> 'note');
  when 'similarity_check' then
    if not (app.user_is_admin(p_user) or app.user_va_has(p_user, 'fleet', 'cs')) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return jsonb_build_object('blocking', app.check_listing_similarity((p_ ->> 'vehicle')::uuid, 'all'), 'flags', app.vehicle_similarity((p_ ->> 'vehicle')::uuid));
  when 'vehicle_similarity' then return app.vehicle_similarity((p_ ->> 'vehicle')::uuid);
  when 'similar_cars' then
    return coalesce((select jsonb_agg(x order by (x ->> 'status' = 'open') desc, (x ->> 'created_at') desc)
                       from (select to_jsonb(f) || jsonb_build_object('vehicle_name', app.vehicle_name(f.vehicle_id), 'other_vehicle_name', app.vehicle_name(f.other_vehicle_id),
                                       'plate', (select v.plate from vehicles v where v.id = f.vehicle_id),
                                       'other_plate', (select v.plate from vehicles v where v.id = f.other_vehicle_id),
                                       'listing_status', (select l.status from vehicle_listings l where l.vehicle_id = f.vehicle_id),
                                       'decided_by_name', (select u.full_name from users u where u.id = f.decided_by)) as x
                               from listing_similarity_flags f
                              where f.status = 'open' or f.decided_at > now() - interval '30 days'
                              order by f.created_at desc limit 300) q), '[]'::jsonb);
  when 'owner_forms_queue' then
    if not (app.user_is_admin(p_user) or app.user_va_has(p_user, 'cs')) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return app.witnessed_forms_queue();
  when 'form_document' then
    -- the scan of a witnessed form, for the reviewer (customer service or an Admin)
    if not (app.user_is_admin(p_user) or app.user_va_has(p_user, 'cs')) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return (select app.document_file(d.id) from documents d
             where d.id = (p_ ->> 'document')::uuid and d.kind in ('form_c_finance_permission_ack', 'form_d_power_of_attorney')
               and exists (select 1 from owner_agreement_forms f where f.document_id = d.id));
  when 'owner_form_review' then return app.review_witnessed_form(p_user, (p_ ->> 'form')::uuid, coalesce((p_ ->> 'approve')::boolean, false), p_ ->> 'reason');
  when 'owner_witnessed_forms' then
    if not (app.user_is_admin(p_user) or app.user_va_has(p_user, 'cs')) then raise exception 'Not permitted' using errcode = '42501'; end if;
    return app.owner_witnessed_forms((p_ ->> 'owner')::uuid);
  when 'driver_links' then
    select * into b from bookings where id::text = p_ ->> 'booking' or booking_number = p_ ->> 'booking';
    return app.booking_driver_links(b.id);
  when 'driver_link_renew' then return app.driver_link_renew((p_ ->> 'signer')::uuid, p_user);
  when 'driver_link_send' then return app.driver_link_send((p_ ->> 'signer')::uuid, p_user, (p_ ->> 'version')::integer, p_ ->> 'url');
  else
    raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;
