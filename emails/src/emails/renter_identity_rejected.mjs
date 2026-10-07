import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_identity_rejected',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Staff reject an identity document, selfie or coverage proof on a confirmed booking (identity verification or coverage proof status becomes rejected). Staff choose the reason; it fills reject_reason.',
  timing: 'Immediate',
  subject: 'Please resend a document for booking {{booking_number}}',
  preheader: 'We could not accept one item. Send a new one by {{verify_by}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Action needed', 'We could not accept one of your documents', 'Your booking still stands, {{first_name}}. We need a new copy of one item before we can hand over the car.'),
    facts(
      ['Item', '{{rejected_item}}'],
      ['Driver', '{{driver_name}}'],
      ['Problem', '{{reject_reason}}'],
    ),
    button('Upload a new one', '@booking_verify'),
    p('Please send it by **{{verify_by}}**. Use good light, keep all four corners in the frame, and make sure the text is sharp.'),
    notice('info', 'If we cannot verify a driver', 'We cancel the booking and refund what you paid. False documents, or no confirmed coverage at pickup, count as a cancellation by you at that time.'),
  ],
  sample: {
    rejected_item: 'Licence, back',
    driver_name: 'Maya Okafor',
    reject_reason: 'The photo is blurred and the barcode cannot be read.',
    verify_by: 'Thu, Oct 22 at 10:00 am',
  },
};
