import { hero, small, h, button, list } from '../components.mjs';
import { FROM } from '../brand.mjs';

// The welcome after the email address is confirmed. The confirmation email itself (with the only link that
// confirms) comes from the sign-in service (scripts/deploy/auth-templates.mjs); this email never asks to confirm.
export default {
  code: 'owner_account_created',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'The person confirms their email address for the first time (the confirmation link from the sign-in service, an invitation or a password link) and has the owner role. Sent once per account. Accounts already confirmed before October 16, 2026 do not get it.',
  timing: 'Immediate',
  subject: 'Your CarmaCars owner account is ready',
  preheader: 'Your email is confirmed. Your owner portal is open.',
  ref: 'Owner account',
  body: [
    hero('Owner account', 'You are all set, {{first_name}}', 'Your email is confirmed and your owner account is open. It is where you sign agreements, follow each vehicle, and see invoices, statements and payouts.'),
    button('Open my owner portal', '@owner'),
    small('Next time, sign in at carmacars.ca with this email and the password you chose.'),
    h('What you can do there'),
    list(
      'Follow each onboarding step of your application',
      'Sign your agreements on screen',
      'See bookings, live location, fee invoices and monthly statements',
    ),
    small('If you did not open this account, reply to this email and we will close it.'),
  ],
};
