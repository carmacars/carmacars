import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_identity_needed',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Booking status becomes confirmed while any driver has identity_status other than verified or the booking has no confirmed coverage option (skipped when renter_booking_confirmed already carried the notice in the same minute). Sent again 48 hours before pickup if anything is still missing.',
  timing: 'On confirmation, then 48 hours before pickup if still missing',
  subject: 'Upload your licence and coverage proof for {{pickup_date}}',
  preheader: 'We need them by {{verify_by}}. No car is released without them.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Documents needed', 'Send us your licence and coverage proof', 'We check every driver before pickup, {{first_name}}. It takes about five minutes on your phone.'),
    notice('alert', 'Due by {{verify_by}}', 'That is 24 hours before your pickup. Without these we cannot hand over the {{vehicle_name}}.'),
    h('For each driver'),
    list(
      'A photo of the front of the driver\'s licence',
      'A photo of the back of the licence',
      'A selfie holding the licence next to your face',
    ),
    small('Every driver must be {{min_renter_age}} or older and hold a G2 or G licence that is valid past the return date.'),
    h('Proof of coverage, or the Protection Plan: one of these'),
    list(
      '**OPCF 27 on your own auto policy.** Send the policy page or a letter from your insurer that shows it.',
      '**Credit card rental coverage.** Send the card\'s benefits certificate. The same card must pay for the rental and be your card on file.',
      '{{#if coverage_for_sale}}**The CarmaCars Protection Plan.** Choose it on the upload page and we send you the terms first.{{else}}If you have neither, reply to this email before the due date and we will go through your options.{{/if}}',
    ),
    button('Upload my documents', '@booking_verify'),
    small('Still missing: {{missing_items}}. A person on our team reviews what you send. We delete licence images and selfies {{id_retention_days}} days after the rental ends.'),
  ],
  sample: { verify_by: 'Thu, Oct 22 at 10:00 am', coverage_for_sale: false, missing_items: 'licence photos, selfie, proof of coverage' },
};
