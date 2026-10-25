import { hero, p, small, compare, button, link, when } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_agreement_version',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'A new version of the booking\'s two rental agreements (CarmaCars\' and Blind Spot\'s) is made after the agreement was signed (migration 0143): the car checked out (the "as picked up" copy), checked in (the closing copy), a correction, or a material change (dates, price, car, drivers, coverage option) that the renter and the affected drivers sign again with their own link. Also sent with the signed copies once every signature of a changed version is in. Both PDFs are attached.',
  timing: 'Immediate',
  subject: '{{version_title}}, booking {{booking_number}}',
  preheader: '{{kind_line}}',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Rental agreement', '{{version_title}}', '{{kind_line}}'),
    when('has_changes', [compare('changes', 'Before', 'Now')]),
    when('needs_signature', [
      button('Read and sign', '@agreement_version_sign'),
      p('You confirm it is you with a code sent to your phone or email, initial the key terms and draw your signature. It takes about three minutes.'),
    ], [
      link('Open your booking and its documents', '@booking'),
    ]),
    small('Every version of your agreements stays in your booking\'s documents. Questions? Reply to this email or call us.'),
  ],
  sample: {
    version_title: 'Version 3 of your rental agreement needs your signature',
    kind_line: 'Your booking changed in a way you sign again. Read what changed, then sign with the button below. Until you sign, the earlier version applies.',
    has_changes: true,
    changes: [
      { label: 'Due back', before: 'Thu, Mar 11, 10:00 am', after: 'Sat, Mar 13, 10:00 am' },
      { label: 'Total', before: '$468.95', after: '$650.95' },
    ],
    needs_signature: true,
    sign_token: '6f1c2b3a-0000-4000-8000-000000000000',
  },
};
