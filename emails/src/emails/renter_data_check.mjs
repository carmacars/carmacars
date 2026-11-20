import { hero, p, button, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_data_check',
  audience: 'renter',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'An Admin pressed Send reminder on a data issue of a renter (Admin > Settings, the data to check; migration 3197): something on their own record looks wrong. Sent once per reminder.',
  timing: 'Immediate, once per reminder',
  subject: 'Please check your CarmaCars details',
  preheader: 'Something on your record to fix, one minute each.',
  ref: 'Your details',
  body: [
    hero('Your details', 'Something to check, {{first_name}}', 'Something on your CarmaCars record looks wrong or is missing: {{issues}}'),
    p('Open your portal: a box shows each one with the field to fix it right there. If it is correct as it is, you can say so and why.'),
    button('Check my details', '{{portal_url}}'),
    small('We ask so your agreements, your trips and your payments go through without delay.'),
  ],
  sample: { issues: 'Your mobile number 555 does not look right: write it with the area code (10 digits).', portal_url: 'https://carmacars.ca/account' },
};
