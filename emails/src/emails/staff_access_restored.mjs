import { hero, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_access_restored',
  audience: 'staff_field',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'An Admin restored a suspended staff account (Unlock on Staff, or approving the person\'s restore request; release 48, migration 3113). Sent once.',
  timing: 'Immediate, once',
  subject: 'Your CarmaCars access is back',
  preheader: 'You can sign in again.',
  ref: 'Staff account',
  body: [
    hero('Staff account', 'Your access is back', 'Hi {{first_name}}. You can sign in to the staff portal again.'),
    button('Sign in', '{{sign_in_url}}'),
  ],
  sample: { sign_in_url: 'https://carmacars.ca/sign-in?next=/staff' },
};
