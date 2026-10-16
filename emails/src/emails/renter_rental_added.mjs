import { hero, p, small, vehicle, facts, price, button, notice, when } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places } from '../snippets.mjs';

export default {
  code: 'renter_rental_added',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'CarmaCars staff add a rental by hand (Admin > Bookings > Add a rental, or the VA equivalent) and it is confirmed at once: paid another way, to be charged to the saved card when the renter signs, or to be invoiced later. Not sent when staff tick "Do not email the renter", for a past rental, or for a payment link (the offer email carries the link).',
  timing: 'Immediate',
  subject: 'Booked: {{vehicle_name}}, {{pickup_date}}',
  preheader: 'Booking {{booking_number}}. {{payment_line}} Next: sign your rental agreement.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Rental booked', 'You are booked, {{first_name}}', 'Our team booked the {{vehicle_name}} for you. Here is everything in one place.'),
    vehicle(),
    trip(),
    places(),
    price({ each: 'line_items', total: ['Total', '{{total_amount}}'] }),
    facts(
      ['Payment', '{{payment_line}}'],
      ['Kilometres included', '{{km_allowance}}, then {{overage_rate}} per km'],
      ['Security deposit', '{{deposit_amount}}, taken at pickup'],
    ),
    notice('info', 'Sign your rental agreement', '{{sign_line}} It takes about two minutes. Sign in with this email address; if you have no account yet, create one with this same address and your booking is there.'),
    button('Sign my rental agreement', '@booking_sign'),
    when('needs_verification', [
      p('We also need each driver\'s licence photos and a selfie, plus proof of your coverage option, by {{verify_by}}. You can upload them from your booking.'),
    ]),
    when('has_balance', [
      small('{{balance_line}}'),
    ]),
  ],
  sample: {
    payment_line: 'Your card is charged when you sign.', sign_line: 'Read and sign your rental agreement; your card is charged when you sign.', has_balance: false, balance_line: '',
    needs_verification: true, verify_by: 'Thu, Oct 22 at 10:00 am',
  },
};
