import { hero, small, button, figure } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip } from '../snippets.mjs';

export default {
  code: 'renter_recovery_pay',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Booking recovery job (every 15 minutes): the renter left the pay page of their approved booking (pending_payment) without paying, recovery_pay_minutes ago (Program settings, 60 by default). At most recovery_max_emails (2), the second after recovery_second_hours (24). Not sent outside the hours set for these emails, to a renter who unsubscribed or turned these reminders off, or while a staff member is already handling the renter. Stops once they pay or the booking leaves pending_payment.',
  timing: 'An hour after the pay page was left',
  subject: 'One step left to book the {{vehicle_name}}',
  preheader: 'Your card is not charged until you finish. Need help? Reply to this email.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Almost booked', 'You are one step away', 'You approved our offer for the {{vehicle_name}}, {{first_name}}, but the payment was not finished. The car is booked only when you sign and pay.'),
    trip(),
    figure('To pay now', '{{total_amount}}', 'HST included. The security deposit is separate and taken at pickup.'),
    button('Finish and pay', '@booking_pay'),
    small('Did the card not go through? Try another credit card in your name, or reply to this email and we will help.'),
  ],
  sample: {},
};
