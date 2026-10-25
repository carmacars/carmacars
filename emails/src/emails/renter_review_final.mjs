import { hero, p, small, button, link } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_review_final',
  audience: 'renter',
  category: 'marketing',
  from: FROM.hello,
  digest: false,
  trigger: 'Review requests (migration 0138): review_final_days (7 by default) after renter_review_ask, the last message of the sequence, with the same rules: 9 am to 9 pm Toronto time, held while a charge is open, stopped once the renter reviewed (on the site, on Google, "I already left a review", or marked by staff) or unsubscribed. Once per booking. Relies on the existing business relationship for consent, so it carries the unsubscribe link and mailing address.',
  timing: '7 days after the review request',
  subject: 'Our last note about your {{vehicle_name}} trip',
  preheader: 'If you have a minute for a review, it helps a lot.',
  ref: 'Booking {{booking_number}}',
  footer: 'You are receiving this because you rented from CarmaCars recently.',
  body: [
    hero('Last note', 'Thanks again, {{first_name}}', 'This is the last time we ask about your trip in the {{vehicle_name}}.'),
    p('If you have a minute, a short review on Google helps a small local company more than you might think. We help you write it from what you tell us.'),
    button('Write a quick review', '{{review_url}}'),
    link('I already left a review', '{{review_done_url}}'),
    small('Something not right? Reply to this email. It reaches a person.'),
  ],
};
