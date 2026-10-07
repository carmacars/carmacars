import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'account_sign_in_link',
  audience: 'renter',
  also: ['owner', 'investor', 'staff_admin', 'staff_va_finance', 'staff_va_fleet', 'staff_va_cs', 'staff_va_sales', 'staff_field'],
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'A one-time sign-in link is requested for any account (the sign-in service magic link event). Also used as the invitation when an admin creates an owner, investor or staff account.',
  timing: 'Immediate',
  subject: 'Your CarmaCars sign-in link',
  preheader: 'Tap to sign in. The link works once and expires in {{link_expiry}}.',
  ref: 'Your account',
  body: [
    hero('Sign in', 'Here is your sign-in link', 'Tap the button on the device you want to use. No password needed.'),
    button('Sign in to CarmaCars', '{{sign_in_url}}'),
    small('The link works once and expires in {{link_expiry}}.'),
    notice('info', 'If you did not ask for this', 'Ignore this email. Nobody can sign in without the link, and we will never ask you to forward it.'),
  ],
};
