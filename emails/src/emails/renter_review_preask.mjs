import { hero, p, small, button, link } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_review_preask',
  audience: 'renter',
  category: 'marketing',
  from: FROM.hello,
  digest: false,
  trigger: 'Review requests (migration 1870, app.job_review_requests every 10 minutes): booking status is on_rent and today is the last full day of the rental (review_preask_days_before, 1 by default, before the return date). It takes the place of the mid-trip check-in that day. Only from review_send_from_hour to review_send_until_hour Toronto time (9 am to 9 pm by default). Never sent when the renter already reviewed (on the site, on Google matched by name, "I already left a review", or marked by staff) or unsubscribed. Once per booking. The after-return requests (1 hour, 24 hours, 7 days) still follow unless a review exists by then.',
  timing: 'The last full day of the rental, 9 am to 9 pm',
  subject: 'Last day with the {{vehicle_name}}',
  preheader: 'If it has been good, a review takes a minute. It also earns Rewards points.',
  ref: 'Booking {{booking_number}}',
  footer: 'You are receiving this because you have a rental with CarmaCars.',
  body: [
    hero('Checking in', 'How is it going, {{first_name}}?', 'Tomorrow is your return day. If anything is off with the {{vehicle_name}}, reply to this email or call us at {{support_phone}}. A person answers.'),
    p('If the trip has gone well, a short review helps the next renter choose, and it earns CarmaCars Rewards points. You can write it now or after you return. It takes about a minute.'),
    button('Write a quick review', '{{review_url}}'),
    small('Nothing to report? No need to reply. Safe travels.'),
    link('I already left a review', '{{review_done_url}}'),
  ],
};
