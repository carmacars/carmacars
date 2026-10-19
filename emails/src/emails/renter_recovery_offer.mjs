import { hero, small, button, figure } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip } from '../snippets.mjs';

export default {
  code: 'renter_recovery_offer',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Booking recovery job (every 15 minutes): the renter opened their offer (page or email link) and has not answered it after recovery_offer_hours (Program settings, 4 by default). At most recovery_max_emails (2) per offer, the second after recovery_second_hours (24). Not sent when the offer expires within 7 hours (the expiry reminder covers it) or an expiry reminder went in the last 12 hours, outside the hours set for these emails, to a renter who unsubscribed or turned these reminders off, or while a staff member is already handling the renter (an assigned task, a chat with a person, a message from staff). Stops once the offer is answered, expires or is withdrawn.',
  timing: 'Some hours after the offer was opened',
  subject: 'Still thinking about the {{vehicle_name}}?',
  preheader: 'Your offer is open until {{offer_expires_at}}. Questions? Reply to this email.',
  ref: 'Request {{booking_number}}',
  body: [
    hero('Your offer', 'Your offer is still open', 'You looked at our offer for the {{vehicle_name}}, {{first_name}}. It is open until {{offer_expires_at}}. If something is not right, tell us and we will adjust it.'),
    trip(),
    figure('Total to pay now', '{{total_amount}}', 'HST included. Nothing is charged until you approve, sign and pay.'),
    button('Review the offer', '@booking_offer'),
    small('Want other dates or a different car? [Ask for a change](@booking_change) or reply to this email. Not interested any more? Do nothing; the offer simply expires.'),
  ],
  sample: { offer_expires_at: 'Wed, Oct 21 at 2:15 pm' },
};
