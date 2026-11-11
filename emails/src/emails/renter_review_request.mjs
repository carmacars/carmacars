import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_review_request',
  audience: 'renter',
  category: 'marketing',
  from: FROM.hello,
  digest: false,
  trigger: '2 days after booking status becomes closed. Only if the renter has not unsubscribed and no review exists for it. A booking that had a problem (an incident, a dispute, an unpaid balance or a damage charge) is not sent automatically: it waits for a staff member to approve it (review_request_decision task, app.decide_review_request). Only an approval sends it, at once; a refusal means it is never sent. Relies on the existing business relationship for consent, so it carries the unsubscribe link and mailing address.',
  timing: '2 days after the booking closes',
  subject: 'Rate your rental of the {{vehicle_name}}',
  preheader: 'Two minutes. Your review helps the next renter choose.',
  ref: 'Booking {{booking_number}}',
  footer: 'You are receiving this because you rented from CarmaCars recently.',
  body: [
    hero('Your review', 'Tell us how it went, {{first_name}}', 'You had the {{vehicle_name}} from {{pickup_date}} to {{return_date}}. Tell us how it went.'),
    vehicle(),
    p('It takes about two minutes. A star rating and a line or two about the car and the handover is plenty. We read every review, and we publish them so other renters can choose well.'),
    button('Write a review', '@booking_review'),
    // r35a: every way to earn reward points after a rental (the amounts are on the Rewards page, from Admin > Rewards)
    h('Earn reward points'),
    list('Review your rental on carmacars.ca, and add a photo of your trip for extra points', 'Review us on Google', 'Follow us on Instagram, TikTok and Facebook from your Rewards page', 'Refer a friend with your own link: you both earn when they complete their first rental', 'Book with us again: every rental after your first earns extra points'),
    link('See your rewards and your referral link', '@account_rewards'),
    small('If something went wrong and you would rather tell us directly, reply to this email. It reaches a person.'),
  ],
};
