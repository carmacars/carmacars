-- 0549: the check-out and check-in report names who took each photo (the renter or staff, by first name) and the
-- suggested angle it was tagged with; photos from the renter's own check-in or checkout links count as the renter's (r28 A3: "all photos on the one check-in/check-out report with who took each").
-- app.handover_report as in 0130 otherwise; create or replace keeps its grants. No applied migration is edited.

create or replace function app.handover_report(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'vehicle', app.vehicle_name(b.vehicle_id),
    'plate', (select v.plate from vehicles v where v.id = b.vehicle_id),
    'pickup_at', b.pickup_at, 'return_at', b.return_at, 'handed_over_at', b.handed_over_at, 'checked_in_at', b.checked_in_at,
    'minutes_late', case when b.checked_in_at is not null then coalesce(b.minutes_late, 0)
                         when b.status = 'on_rent' and now() > b.return_at then floor(extract(epoch from (now() - b.return_at)) / 60)::integer else 0 end,
    'overdue', b.status = 'on_rent' and now() > b.return_at,
    'grace_minutes', (select t.grace_minutes from app.booking_fee_term(b.id, 'late_return_fee') t),
    'extra_days', b.extra_days,
    'km_out', b.odometer_out_km, 'km_in', b.odometer_in_km, 'km_driven', app.booking_km_driven(b.id), 'km_allowance', b.km_allowance_total,
    'km_over', greatest(coalesce(app.booking_km_driven(b.id), 0) - coalesce(b.km_allowance_total, 0), 0),
    'overage_cents_per_km', b.overage_cents_per_km,
    'fuel_out_pct', b.fuel_out_pct, 'fuel_in_pct', b.fuel_in_pct,
    'fuel_short_pct', greatest(coalesce(b.fuel_out_pct, 0) - coalesce(b.fuel_in_pct, b.fuel_out_pct, 0), 0),
    'electric', (select v.fuel::text = 'electric' from vehicles v where v.id = b.vehicle_id),
    'reports', coalesce((select jsonb_agg(jsonb_build_object(
        'id', c.id, 'kind', c.kind, 'performed_at', c.performed_at, 'completed_at', c.completed_at,
        'performed_by_name', (select u.full_name from users u where u.id = c.performed_by), 'odometer_km', c.odometer_km, 'fuel_pct', c.fuel_pct,
        'keys_count', c.keys_count, 'cleanliness', c.cleanliness, 'notes', c.notes, 'unattended', c.unattended,
        'renter_signed_at', c.renter_signed_at, 'staff_signed_at', c.staff_signed_at, 'renter_declined_to_sign', c.renter_declined_to_sign,
        'photos', coalesce((select jsonb_agg(jsonb_build_object('seq', p.seq, 'shot', p.shot, 'bucket', p.storage_bucket, 'path', p.storage_path,
                                     'taken_at', coalesce(p.device_taken_at, p.taken_at), 'latitude', p.latitude, 'longitude', p.longitude,
                                     'damage_label', (select d.label from condition_report_damages d where d.id = p.damage_id),
                                     'angle', p.angle,
                                     'taken_by', case when p.storage_path ~ '/(return-claim|self-pickup)/'
                                                        or p.uploaded_by = (select r.user_id from renters r where r.id = b.renter_id) then 'renter'
                                                      when p.uploaded_by is not null then 'staff' end,
                                     'taken_by_name', case when p.storage_path ~ '/(return-claim|self-pickup)/'
                                                             or p.uploaded_by = (select r.user_id from renters r where r.id = b.renter_id) then 'Renter'
                                                           else (select split_part(u.full_name, ' ', 1) from users u where u.id = p.uploaded_by) end) order by p.seq)
                             from condition_report_photos p where p.condition_report_id = c.id and p.shot <> 'licence'), '[]'::jsonb),
        'damages', coalesce((select jsonb_agg(jsonb_build_object('label', d.label, 'location', d.location, 'description', d.description, 'kind', d.kind,
                                     'size_cm', d.size_cm, 'is_new', d.is_new, 'found_later', d.found_later, 'status_vs_pickup', d.status_vs_pickup) order by d.label)
                              from condition_report_damages d where d.condition_report_id = c.id), '[]'::jsonb))
        order by case c.kind when 'pickup' then 1 when 'swap_out' then 2 when 'swap_in' then 3 else 4 end)
       from condition_reports c where c.booking_id = b.id and c.kind in ('pickup', 'return', 'swap_out', 'swap_in') and c.completed_at is not null), '[]'::jsonb),
    'charges', coalesce((select jsonb_agg(jsonb_build_object('key', li.assessment_key, 'label', li.description, 'amount_cents', li.amount_cents,
                                 'hst_cents', li.hst_cents, 'on_statement', li.statement_id is not null) order by li.created_at)
                         from booking_line_items li where li.booking_id = b.id and li.voided_at is null and li.assessment_key is not null
                           and li.assessment_key !~ '^damage'), '[]'::jsonb),
    'waivers', coalesce((select jsonb_agg(jsonb_build_object('key', w.assessment_key, 'reason', w.reason, 'by', (select u.full_name from users u where u.id = w.waived_by),
                                 'at', w.waived_at) order by w.waived_at) from check_in_waivers w where w.booking_id = b.id), '[]'::jsonb))
    from bookings b where b.id = p_booking
$$;
