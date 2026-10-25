import { hero, p, small, button, link, vehicle } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_review_ask',
  audience: 'renter',
  category: 'marketing',
  from: FROM.hello,
  digest: false,
  trigger: 'Review requests (migration 0138, app.job_review_requests every 10 minutes): review_ask_after_minutes (60 by default) after the car is checked in (booking status returned or closed). Only from 9 am to 9 pm Toronto time (Program settings). Never while a return or later charge (late, kilometres, fuel, cleaning, smoking, damage, tolls) is not settled or waived, nor with an open incident or dispute: the booking waits on the hold list and is released by itself, or by staff with Send anyway. Not sent when the renter already reviewed (on the site, on Google matched by name, "I already left a review", or marked by staff) or unsubscribed. Staff can also send it from the booking (Ask for a review). Never depends on a rating and offers nothing for a review. Relies on the existing business relationship for consent, so it carries the unsubscribe link and mailing address.',
  timing: '1 hour after the check-in, 9 am to 9 pm',
  subject: 'How was the {{vehicle_name}}?',
  preheader: 'A quick review takes a minute. We help you write it.',
  ref: 'Booking {{booking_number}}',
  footer: 'You are receiving this because you rented from CarmaCars recently.',
  body: [
    hero('Your review', 'Thanks for renting with us, {{first_name}}', 'You had the {{vehicle_name}} from {{pickup_date}} to {{return_date}}. Would you tell other renters how it went?'),
    vehicle(),
    p('It takes about a minute. Tap what you liked, add a sentence in your own words, and we put it together for you to check, change and post on Google.'),
    button('Write a quick review', '{{review_url}}'),
    small('Something not right? Reply to this email. It reaches a person, and we would rather fix it.'),
    link('I already left a review', '{{review_done_url}}'),
  ],
};
