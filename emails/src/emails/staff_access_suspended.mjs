import { hero, p, button, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_access_suspended',
  audience: 'staff_field',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'A staff account (never an Admin) was suspended: no use of the staff portal for the days of Program settings (5 by default), or two weekly townhalls missed in a row (release 48, migration 3113). Sent once per suspension. While suspended this is the only kind of message the person gets (with the restored email), nothing else.',
  timing: 'Immediate, once',
  subject: 'You no longer have access to CarmaCars',
  preheader: 'Click here to restore it.',
  ref: 'Staff account',
  body: [
    hero('Staff account', 'You no longer have access', 'Hi {{first_name}}. Your CarmaCars staff account is suspended.'),
    button('Click here to restore it', '{{restore_url}}'),
    small('An Admin approves the request, then you can sign in again.'),
  ],
  sample: { restore_url: 'https://carmacars.ca/staff-restore?t=3f1c7a2e-5b0d-4c1e-9a77-2b6c1d0e8f41' },
};
