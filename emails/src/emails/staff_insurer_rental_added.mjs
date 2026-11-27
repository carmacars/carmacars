import { hero, facts, button, list } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_insurer_rental_added',
  audience: 'staff_va_finance',
  also: ['staff_admin'],
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'Release 50 (5120): an insurance replacement is added from Insurance replacements (the page or the CarmaCars_Admin connector). To Finance and the Admins, once per rental, so the claim is invoiced and chased.',
  timing: 'Immediate, when the rental is added',
  subject: 'Insurance replacement {{booking_number}}: {{insurer_name}}, claim {{claim_number}}',
  preheader: '{{renter_name}}, {{vehicle_name}}, {{period}}. Added by {{added_by}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Insurance replacement', 'A rental for {{insurer_name}}', '{{added_by}} added an insurance replacement. Check the claim and the adjuster, then send the estimate or the invoice.'),
    facts(
      ['Booking', '{{booking_number}}'],
      ['Insurer', '{{insurer_name}}'],
      ['Claim no.', '{{claim_number}}'],
      ['Renter', '{{renter_name}}'],
      ['Car', '{{vehicle_name}}'],
      ['Dates', '{{period}}'],
    ),
    button('Open the rental', '@insurer_rental'),
    list(
      'Check the adjuster and the bill-to details on the invoice.',
      'Send an estimate now if the adjuster asks for one; send the invoice when the rental ends.',
      'Record what the adjuster approves and each payment the day it arrives.',
    ),
  ],
  sample: {
    booking_number: 'CC-10482', insurer_name: 'Northern Mutual Insurance (sample)', claim_number: 'CL-88213-A', renter_name: 'Maya Chen',
    vehicle_name: '2023 Toyota RAV4 XLE', period: 'Fri, Nov 27, 2026 to Mon, Dec 7, 2026', added_by: 'Jordan Example',
  },
};
