import { hero, p, small, facts, compare, button, when } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_coverage_switched',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Staff (an Admin, customer service, sales or fleet) switch a confirmed or active booking between the renter\'s credit card rental coverage and the CarmaCars Protection Plan. Sent once the switch is saved, with what changed, the new price and what the renter does next. A booking that is still an offer gets the revised offer email instead.',
  timing: 'Immediate',
  subject: 'Your coverage on booking {{booking_number}} changed',
  preheader: 'Here is the new price and what to do next.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Coverage updated', '{{coverage_title}}', 'Hello {{first_name}}, here is what changed on your booking.'),
    compare('change_rows', 'Before', 'Now'),
    facts(
      ['Coverage now', '{{coverage_now}}'],
      ['Payment', '{{money_text}}'],
    ),
    p('{{next_step}}'),
    when('has_reason', [
      p('Note from our team: {{switch_reason}}'),
    ]),
    button('View your booking', '@booking'),
    small('Your rental agreement is updated to match and kept with your booking. If anything here looks wrong, reply to this email and we will fix it.'),
  ],
  sample: {
    change_rows: [
      { label: 'Coverage', before: 'Rental coverage on your credit card', after: 'The CarmaCars Protection Plan' },
      { label: 'Total with HST', before: '$468.95', after: '$581.95' },
    ],
    coverage_title: 'Your booking now has the Protection Plan',
    coverage_now: 'The CarmaCars Protection Plan',
    money_text: 'You have $113.00 more to pay. We will send you a secure payment link, or you can pay from your booking page.',
    next_step: 'You do not need to send a card coverage document any more. We confirm the Protection Plan for you before pickup.',
    has_reason: true, switch_reason: 'Your credit card does not include rental coverage for this car.',
  },
};
