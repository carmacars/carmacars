import { hero, p, small, figure } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_signing_code',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'A renter or driver about to sign a rental agreement, an amendment or a new version asks for the identity code by email (migration 0154). The code proves the signer controls the email on file; it is never stored in clear.',
  timing: 'Immediate',
  subject: 'Your CarmaCars signing code: {{code}}',
  preheader: 'Enter it on the signing page within {{minutes}} minutes.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Signing code', 'Confirm it is you', 'Enter this code on the signing page to sign your rental agreement.'),
    figure('Your code', '{{code}}', 'It expires in {{minutes}} minutes.'),
    p('If you did not ask for it, someone may be trying to sign in your name: do not share the code, and call us.'),
    small('CarmaCars never asks for this code by phone.'),
  ],
  sample: { code: '482913', minutes: '10' },
};
