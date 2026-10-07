import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_account_created',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'A user with the owner role is created (owner sign-up, or created by staff from an application) and the email address is not yet verified.',
  timing: 'Immediate',
  subject: 'Confirm your email to open your CarmaCars owner account',
  preheader: 'One tap confirms your email. The link works for {{link_expiry}}.',
  ref: 'Owner account',
  body: [
    hero('Owner account', 'Confirm your email, {{first_name}}', 'Your owner account is where you sign agreements, follow each vehicle, and see invoices, statements and payouts.'),
    button('Confirm my email', '{{verify_url}}'),
    small('The link works once and expires in {{link_expiry}}. If it has expired, sign in and we will send a new one.'),
    h('What you can do there'),
    list(
      'Apply to enrol a vehicle and track each onboarding step',
      'Sign your agreements on screen',
      'See bookings, live location, fee invoices and monthly statements',
    ),
    small('If you did not open this account, ignore this email and nothing happens.'),
  ],
};
