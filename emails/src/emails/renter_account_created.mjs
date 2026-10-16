import { hero, button, small, steps } from '../components.mjs';
import { FROM } from '../brand.mjs';

// The welcome after the email address is confirmed. The confirmation email itself (with the only link that
// confirms) comes from the sign-in service (scripts/deploy/auth-templates.mjs); this email never asks to confirm.
export default {
  code: 'renter_account_created',
  audience: 'renter',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'The person confirms their email address for the first time (the confirmation link from the sign-in service, or a password link for an address already on file from a booking request) and has the renter role only. Sent once per account. Accounts already confirmed before October 16, 2026 do not get it.',
  timing: 'Immediate',
  subject: 'Your CarmaCars account is ready',
  preheader: 'Your email is confirmed. Request a car whenever you are ready.',
  ref: 'Your account',
  body: [
    hero('Welcome', 'You are all set, {{first_name}}', 'Your email is confirmed and your CarmaCars account is open. Offers, agreements and receipts will come to this address.'),
    button('Browse cars', '@cars'),
    small('Next time, sign in at carmacars.ca with this email and the password you chose.'),
    steps(
      ['Request a car', 'Pick your dates and send a request. No card is needed to ask.'],
      ['Get our offer', 'We check the car and reply with a firm price. An offer does not hold the car.'],
      ['Approve, sign and pay', 'Your booking is confirmed once the agreement is signed and paid.'],
    ),
    small('If you did not open this account, reply to this email and we will close it.'),
  ],
};
