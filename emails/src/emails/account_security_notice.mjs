import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'account_security_notice',
  audience: 'renter',
  also: ['owner', 'investor', 'staff_admin', 'staff_va_finance', 'staff_va_fleet', 'staff_va_cs', 'staff_va_sales', 'staff_field'],
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'A security event on any account: a sign-in from a device or browser not seen before on that account, a password change, or a change of the account email address. One template for every account type. For an email change it is sent to both the old and the new address. Never batched.',
  timing: 'Immediate',
  subject: 'Security notice: {{security_event}} on your CarmaCars account',
  preheader: '{{security_event_at}}. If this was you, there is nothing to do.',
  ref: 'Security notice',
  body: [
    hero('Security notice', '{{security_event}}', 'This happened on your CarmaCars account, {{first_name}}. If it was you, there is nothing to do.'),
    facts(
      ['What', '{{security_event}}'],
      ['When', '{{security_event_at}}'],
      ['Device', '{{security_device}}'],
      ['Approximate place', '{{security_place}}'],
    ),
    notice('alert', 'If this was not you', 'Set a new password now. Then reply to this email or call {{support_phone}} so we can check your account.'),
    button('Set a new password', '{{reset_url}}'),
    small('The link works once and expires in {{link_expiry}}. We will never ask you for your password or for this link.'),
  ],
  sample: {
    security_event: 'New sign-in', security_event_at: 'Tue, Oct 20, 2026 at 8:41 pm', security_device: 'Chrome on Windows',
    security_place: 'Mississauga, Ontario',
  },
};
