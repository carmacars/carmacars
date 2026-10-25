import { hero, p, small, button, link } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_review_reminder',
  audience: 'renter',
  category: 'marketing',
  from: FROM.hello,
  digest: false,
  trigger: 'Review requests (migration 0138): review_reminder_hours (24 by default) after renter_review_ask, with the same rules: 9 am to 9 pm Toronto time, held while a charge is open, stopped once the renter reviewed (on the site, on Google, "I already left a review", or marked by staff) or unsubscribed. Once per booking. Relies on the existing business relationship for consent, so it carries the unsubscribe link and mailing address.',
  timing: '24 hours after the review request',
  subject: 'A minute for a review of the {{vehicle_name}}?',
  preheader: 'Tap what you liked, add a sentence, done.',
  ref: 'Booking {{booking_number}}',
  footer: 'You are receiving this because you rented from CarmaCars recently.',
  body: [
    hero('Quick reminder', 'Your review helps the next renter, {{first_name}}', 'People nearby choose a rental company by what renters like you say.'),
    p('Tap what you liked about the {{vehicle_name}}, add a sentence, and post it on Google. Good or bad, we read every review and reply to it.'),
    button('Write a quick review', '{{review_url}}'),
    link('I already left a review', '{{review_done_url}}'),
    small('Something not right? Reply to this email and a person will help.'),
  ],
};
