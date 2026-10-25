import { hero, p, small, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_trip_checkin',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Review requests (migration 0138, app.job_review_requests every 10 minutes): booking status is on_rent, the rental is at least review_checkin_min_days long (2 by default) and review_checkin_after_hours (24 by default) have passed since the pickup, never in the last 6 hours before the return. Only from review_send_from_hour to review_send_until_hour Toronto time (9 am to 9 pm by default). A service message about the rental in progress: it asks for no review. Once per booking.',
  timing: '24 hours after the pickup, rentals of 2 days or more',
  subject: 'How is the {{vehicle_name}} going?',
  preheader: 'If anything is off, reply or call. We fix it.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Checking in', 'How is the car, {{first_name}}?', 'You have had the {{vehicle_name}} for a day now. We want the rest of your trip to go smoothly.'),
    p('If anything is off, big or small (a warning light, a noise, something missing, something not clean), reply to this email or call us at {{support_phone}}. A person answers and we sort it out.'),
    button('Open my booking', '@booking'),
    small('Nothing to report? No need to reply. Enjoy the rest of your trip.'),
  ],
};
