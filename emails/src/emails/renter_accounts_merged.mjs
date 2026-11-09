import { hero, p, small, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

// Two renter records of the same person were merged (migration 0955): the one note the renter gets about it.
export default {
  code: 'renter_accounts_merged',
  audience: 'renter',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'Two renter records of the same person were merged (automatically, or by staff with Merge into this record). Once per merge: the renter learns they can sign in with any of their emails or their phone number. Nothing else is sent about a merge.',
  timing: 'Immediate',
  subject: 'Your CarmaCars accounts are now one',
  preheader: 'Sign in with {{sign_in_emails}} or your phone number.',
  ref: 'Your account',
  body: [
    hero('Your account', 'Your accounts are now one', 'Hi {{first_name}}, you had two CarmaCars accounts, so we joined them. Your bookings, documents, cards and messages are all in one place now.'),
    p('Sign in with {{sign_in_emails}}, or with your phone number and a code we text you. Your password stays the one you chose.'),
    button('Open my account', '@account'),
    small('If these were not both yours, reply to this email and we will separate them.'),
  ],
  sample: { sign_in_emails: 'sam@example.com or sam.work@example.com' },
};
