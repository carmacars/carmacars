import { hero, p, button, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_inactivity_warning',
  audience: 'staff_field',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'A staff account (never an Admin) has had no sign-in or use of the staff portal for the warning days of Program settings (3 by default since release 48, migration 3113; 7 before). Sent once per idle stretch.',
  timing: 'On the warning day, once',
  subject: 'Your CarmaCars staff access ends on {{lock_on}}',
  preheader: 'Sign in before then to keep it.',
  ref: 'Staff account',
  body: [
    hero('Staff account', 'Sign in to keep your access', 'Hi {{first_name}}. You have not signed in to your CarmaCars staff portal for {{days_idle}} days.'),
    p('Staff access is suspended after {{lock_days}} days in a row without using the portal. Yours is suspended on {{lock_on}} unless you sign in before then.'),
    button('Sign in now', '{{sign_in_url}}'),
    small('If you no longer work with CarmaCars, there is nothing to do.'),
  ],
  sample: { days_idle: '3', lock_days: '5', lock_on: 'Thursday, November 12', sign_in_url: 'https://carmacars.ca/sign-in?next=/staff' },
};
