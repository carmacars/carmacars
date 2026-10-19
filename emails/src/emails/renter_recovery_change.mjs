import { hero, small, button, facts } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_recovery_change',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Booking recovery job (every 15 minutes): the renter opened a change staff proposed to their booking and has not answered it after recovery_change_hours (Program settings, 4 by default). At most recovery_max_emails (2), the second after recovery_second_hours (24). Not sent when the deadline is within the change reminder hours (that reminder covers it), outside the hours set for these emails, to a renter who unsubscribed or turned these reminders off, or while a staff member is already handling the renter. Stops once the change is accepted, declined or expires.',
  timing: 'Some hours after the proposal was opened',
  subject: 'Your answer to the change to booking {{booking_number}}',
  preheader: 'Answer by {{accept_by}}. If you do nothing, your booking stays as it is.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Change to your booking', 'We are waiting for your answer', 'You opened the change we proposed to your booking of the {{vehicle_name}}, {{first_name}}. Please accept or decline it by {{accept_by}}.'),
    facts(
      ['Booking', '{{booking_number}}'],
      ['Answer by', '{{accept_by}}'],
    ),
    button('Review and answer', '@booking_change'),
    small('Questions about the change? Reply to this email. If you do not answer, your booking stays exactly as it is.'),
  ],
  sample: { accept_by: 'Sat, Oct 24 at 10:00 am' },
};
