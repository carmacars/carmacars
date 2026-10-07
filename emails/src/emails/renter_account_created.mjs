import { hero, p, button, small, steps } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_account_created',
  audience: 'renter',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'A user with the renter role is created (sign-up form, or the account made with a first booking request) and the email address is not yet verified.',
  timing: 'Immediate',
  subject: 'Confirm your email to finish your CarmaCars account',
  preheader: 'One tap confirms your email. The link works for {{link_expiry}}.',
  ref: 'Your account',
  body: [
    hero('Welcome', 'Confirm your email, {{first_name}}', 'Your CarmaCars account is open. Confirm this email address so we can send you offers, agreements and receipts.'),
    button('Confirm my email', '{{verify_url}}'),
    small('The link works once and expires in {{link_expiry}}. If it has expired, sign in and we will send a new one.'),
    steps(
      ['Request a car', 'Pick your dates and send a request. No card is needed to ask.'],
      ['Get our offer', 'We check the car and reply with a firm price. An offer does not hold the car.'],
      ['Approve, sign and pay', 'Your booking is confirmed once the agreement is signed and paid.'],
    ),
    small('If you did not open this account, ignore this email and nothing happens.'),
  ],
};
