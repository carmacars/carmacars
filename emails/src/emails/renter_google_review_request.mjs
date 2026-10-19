import { hero, p, small, button, vehicle } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_google_review_request',
  audience: 'renter',
  category: 'marketing',
  from: FROM.hello,
  digest: false,
  trigger: 'Program settings google_review_delay_days (3 by default) after booking status becomes closed, only when the Google place id is set in Site settings (app.notify_google_reviews, migration 0061). The same rules as renter_review_request: not unsubscribed, nothing unpaid or open on the renter, and a booking that had a problem (an incident, a dispute, an unpaid balance or a damage charge) is sent only after a staff member answers yes to the review request decision. Never depends on the rating the renter gave, and offers nothing for a review. One per booking. Relies on the existing business relationship for consent, so it carries the unsubscribe link and mailing address.',
  timing: 'google_review_delay_days after the booking closes',
  subject: 'Would you review CarmaCars on Google?',
  preheader: 'A line or two helps other renters choose.',
  ref: 'Booking {{booking_number}}',
  footer: 'You are receiving this because you rented from CarmaCars recently.',
  body: [
    hero('Google review', 'Tell other renters how it went, {{first_name}}', 'You rented the {{vehicle_name}} from {{pickup_date}} to {{return_date}}. A short review on Google helps people nearby find a rental company they can trust.'),
    vehicle(),
    p('Write whatever you think, good or bad. It takes a minute, and we read every review and reply to it.'),
    button('Review CarmaCars on Google', '{{google_review_url}}'),
    small('If something went wrong and you would rather tell us directly, reply to this email. It reaches a person.'),
  ],
};
