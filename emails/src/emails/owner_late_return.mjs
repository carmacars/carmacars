import { hero, small, facts, notice, button, rows, when } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_late_return',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'A rental of the owner\'s car is still out 2 hours (late_admin_minutes) after its return time with no paid extension (r49, app.job_r49_notices, every 5 minutes), once per return time. Sent only when the booking counts toward the owner\'s revenue (app.owner_mail_booking). Not for Owner Bookings, Turo trips or an insurer rental with no known end date. The return itself is told by owner_trip_completed.',
  timing: '2 hours after the return time',
  subject: 'Your {{vehicle_name}} is late coming back',
  preheader: 'Booking {{booking_number}} was due back {{return_date}}, {{return_time}}. We are on it.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Late return', 'Your {{vehicle_name}} is not back yet', 'Hi {{first_name}}, the renter has kept the car {{late_by}} past the return time. Our team is calling the renter and checking the tracker.'),
    facts(
      ['Due back', '{{return_date}}, {{return_time}}'],
      ['Late by', '{{late_by}}'],
      ['Booking', '{{booking_number}}'],
    ),
    notice('info', 'Nothing for you to do', 'We tell you again as soon as the car is back. Late days are charged to the renter under the agreement.'),
    button('View this trip', '@owner_booking'),
    small('You get this once, when a car is 2 hours late. Every trip that comes back also has its own email.'),
  ],
  sample: { first_name: 'Daniel', vehicle_name: '2023 Toyota RAV4 XLE', return_time: '5:00 pm', late_by: '2 hours' },
};
