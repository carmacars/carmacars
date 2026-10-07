import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_agreement_signed',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'A rental agreement signature request is completed (every signer has signed and CarmaCars has countersigned). Sent to the renter and to each additional driver who signed.',
  timing: 'Immediate',
  subject: 'Your signed rental agreement, booking {{booking_number}}',
  preheader: 'Keep this copy. It sets the terms of your rental.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Agreement signed', 'Here is your signed agreement', 'Everyone has signed the rental agreement for the {{vehicle_name}}. This is your copy to keep, {{first_name}}.'),
    facts(
      ['Agreement no.', '{{booking_number}}'],
      ['Signed', '{{signed_at}}'],
      ['Signed by', '{{signers}}'],
    ),
    button('Download the signed agreement', '{{signed_agreement_url}}'),
    small('The download link works for 7 days. After that, the agreement is always in [your booking](@booking).'),
  ],
  sample: { signed_at: 'Tue, Oct 20, 2026 at 4:42 pm', signers: 'Maya Okafor, CarmaCars' },
};
