import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'account_password_reset',
  audience: 'renter',
  also: ['owner', 'investor', 'staff_admin', 'staff_va_finance', 'staff_va_fleet', 'staff_va_cs', 'staff_va_sales', 'staff_field'],
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'A password reset is requested for any account (the sign-in service recovery event). One template for every account type.',
  timing: 'Immediate',
  subject: 'Reset your CarmaCars password',
  preheader: 'The link works once and expires in {{link_expiry}}.',
  ref: 'Your account',
  body: [
    hero('Account security', 'Reset your password', 'Someone asked to reset the password for this CarmaCars account. If that was you, choose a new one now.'),
    button('Choose a new password', '{{reset_url}}'),
    small('The link works once and expires in {{link_expiry}}.'),
    notice('info', 'If this was not you', 'Ignore this email. Your password stays the same and nobody can get in with this link unless they can read your inbox.'),
  ],
};
