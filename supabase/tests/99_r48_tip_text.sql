-- 99: the text of the return carries the tip link (migration 3072, docs/changes/2026-11-16-r48-integration.md).
select test.suite('99 r48 tip text');
select test.eq('the Returned text has the tip link once, with the booking number',
  app.sms_render((select body from sms_templates where code = 'renter_return_complete'), jsonb_build_object('vehicle_name', 'Civic', 'link', 'https://carmacars.ca/x', 'booking_number', 'CC-1')) ~ 'Add a tip: https://carmacars.ca/account/bookings/CC-1/tip$'
  and (select length(body) - length(replace(body, '/tip', '')) from sms_templates where code = 'renter_return_complete') = 4, true);
