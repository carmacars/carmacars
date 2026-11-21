-- 99: the owner's new-booking emails, opted in (migration 3354). owner_new_booking, owner_booking_confirmed and
-- owner_booking_changed stay off in the catalogue (2620); an owner who turned "New bookings on your cars" on (3260) gets
-- them on the channels chosen; an owner who did not hears nothing. Fixtures start with "obe"; addresses are example.test.
select test.suite('99 r48int owner new-booking emails (3354)');

select test.mk_owner('obe_quiet');
select test.mk_owner('obe_keen');
select test.mk_vehicle('OBEQ', 'obe_quiet');
select test.mk_vehicle('OBEK', 'obe_keen');
select test.mk_renter('obe_ren');
select test.mk_booking('OBE-Q1', 'OBEQ', 'obe_ren', to_char(now() + interval '10 days', 'YYYY-MM-DD 10:00'), to_char(now() + interval '13 days', 'YYYY-MM-DD 10:00'), 'confirmed');
select test.mk_booking('OBE-K1', 'OBEK', 'obe_ren', to_char(now() + interval '10 days', 'YYYY-MM-DD 10:00'), to_char(now() + interval '13 days', 'YYYY-MM-DD 10:00'), 'confirmed');

select test.eq('the three codes stay off in the catalogue, and their type is off by default on every channel',
  (select string_agg(code || ':' || is_enabled || ':' || coalesce(pref_type, '-'), ',' order by code) from notification_catalogue where code in ('owner_new_booking', 'owner_booking_confirmed', 'owner_booking_changed'))
    || ' ' || (select push_default or email_default or text_default from notify_types where code = 'owner_new_bookings'),
  'owner_booking_changed:false:owner_new_bookings,owner_booking_confirmed:false:owner_new_bookings,owner_new_booking:false:owner_new_bookings false');

-- the keen owner turns the email on (the quiet one leaves the default)
select public.server_notify_prefs_save(test.id('obe_keen'), '{"type": "owner_new_bookings", "channel": "email", "on": true, "portal": "owner"}'::jsonb);

-- what the booking status trigger emits on a confirmation (0023)
select app.ntf_emit('owner_new_booking', 'booking', b.id, 'confirmed', jsonb_build_object('booking_id', b.id)) from bookings b where b.id in (test.id('booking:OBE-Q1'), test.id('booking:OBE-K1'));
select app.process_events(100000);

select test.eq('an owner who did not opt in: the event is closed as before, nothing is sent or shown',
  (select e.process_note from app_events e where e.code = 'owner_new_booking' and e.entity_id = test.id('booking:OBE-Q1'))
    || ' ' || (select count(*) from notification_outbox o where o.code = 'owner_new_booking' and o.booking_id = test.id('booking:OBE-Q1'))
    || ' ' || (select count(*) from notifications n where n.code = 'owner_new_booking' and n.user_id = test.id('obe_quiet')),
  'code disabled 0 0');
select test.eq('an owner who opted in: the email is queued to the car''s owner, and the notice shows in the portal',
  (select format('%s|%s|%s', count(*), min(o.status), bool_and(o.owner_id = test.id('owner:obe_keen'))) from notification_outbox o where o.code = 'owner_new_booking' and o.booking_id = test.id('booking:OBE-K1'))
    || ' ' || (select count(*) from notifications n where n.code = 'owner_new_booking' and n.user_id = test.id('obe_keen')),
  '1|queued|t 1');
select test.eq('...with every variable filled', (select count(*) from notification_outbox where code = 'owner_new_booking' and booking_id = test.id('booking:OBE-K1') and cardinality(missing_variables) > 0), 0::bigint);
select test.eq('...on the channels the owner chose: no text (the text stays off)',
  (select count(*) from phone_outbox p where p.sms_kind = 'owner_new_booking' and p.status = 'queued' and p.user_id = test.id('obe_keen')), 0::bigint);

-- switched off again: nothing more
select public.server_notify_prefs_save(test.id('obe_keen'), '{"type": "owner_new_bookings", "channel": "email", "on": false, "portal": "owner"}'::jsonb);
select app.emit_event('owner_booking_changed', 'booking', test.id('booking:OBE-K1'), jsonb_build_object('booking_id', test.id('booking:OBE-K1')), 'obe:changed:1');
select app.process_events(100000);
select test.eq('switched off again: the change is closed as before',
  (select e.process_note from app_events e where e.dedupe_key = 'obe:changed:1'), 'code disabled');
