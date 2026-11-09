import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_identity_needed',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Reminders job: 48 hours before pickup, a confirmed booking still needs something the renter sends (a driver\'s licence photos or selfie not uploaded or rejected, or the proof of coverage not sent). Nothing is sent for what is already uploaded and waiting for our review, nor when the confirmation that already listed it went out within the reminder gap (Program settings, 12 hours by default, migration 0900). The subject and the copy name only what is missing.',
  timing: '48 hours before pickup if still missing',
  subject: '{{needed_title}} for {{pickup_date}}',
  preheader: 'We need them by {{verify_by}}. No car is released without them.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Documents needed', '{{needed_title}}', 'We check every driver before pickup, {{first_name}}. It takes about five minutes on your phone.'),
    notice('alert', 'Due by {{verify_by}}', 'That is 24 hours before your pickup. Without these we cannot hand over the {{vehicle_name}}.'),
    when('needs_licence', [
      h('For each driver still to check'),
      list(
        'A photo of the front of the driver\'s licence',
        'A photo of the back of the licence',
        'A selfie holding the licence next to your face',
      ),
      small('Every driver must be {{min_renter_age}} or older and hold a G2 or G licence that is valid past the return date.'),
    ]),
    when('needs_coverage', [
      h('Proof of coverage, or the Protection Plan: one of these'),
      list(
        '**OPCF 27 on your own auto policy.** Send the policy page or a letter from your insurer that shows it.',
        '**Credit card rental coverage.** Send the card\'s benefits certificate. The same card must pay for the rental and be your card on file.',
        '{{#if coverage_for_sale}}**The CarmaCars Protection Plan.** Choose it on the upload page and we send you the terms first.{{else}}If you have neither, reply to this email before the due date and we will go through your options.{{/if}}',
      ),
    ]),
    button('Upload what is missing', '@booking_verify'),
    small('Still missing: {{needed_items}}. A person on our team reviews what you send. We delete licence images and selfies {{id_retention_days}} days after the rental ends.'),
  ],
  sample: { verify_by: 'Thu, Oct 22 at 10:00 am', coverage_for_sale: false, needed_title: 'Send your proof of coverage', needs_licence: false, needs_coverage: true, needed_items: 'proof of coverage' },
};
