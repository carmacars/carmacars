import { hero, p, button, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_inactivity_warning',
  audience: 'staff_field',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'A staff account (never an Admin) has had no sign-in or use of the staff portal for the warning days of Program settings (7 by default; migration 1060). Sent once per idle stretch.',
  timing: 'On the warning day, once',
  subject: 'Your CarmaCars staff account locks on {{lock_on}}',
  preheader: 'Sign in before then to keep it open.',
  ref: 'Staff account',
  body: [
    hero('Staff account', 'Sign in to keep your account open', 'Hi {{first_name}}. You have not signed in to your CarmaCars staff portal for {{days_idle}} days.'),
    p('Staff accounts lock after {{lock_days}} days without a sign-in. Yours locks on {{lock_on}} unless you sign in before then. Once it is locked, only an Admin can open it again.'),
    button('Sign in now', '{{sign_in_url}}'),
    small('If you no longer work with CarmaCars, there is nothing to do.'),
  ],
  sample: { days_idle: '7', lock_days: '10', lock_on: 'Thursday, November 12', sign_in_url: 'https://carmacars.ca/sign-in?next=/staff' },
};
