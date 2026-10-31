import { hero, p, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'applicant_unconfirmed',
  audience: 'applicant',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'A candidate for a remote role did not confirm their interview call in time (12 hours after the confirmation email, or 1 hour before the call, whichever is sooner): the call is cancelled and the time opens again (migration 0229). One email per booking.',
  timing: 'When the call is cancelled',
  subject: 'Your CarmaCars interview call was cancelled',
  preheader: 'It was not confirmed in time. You can book again from your link.',
  ref: 'Careers',
  body: [
    hero('Careers', 'Your call was cancelled, {{first_name}}', 'Your interview call for {{role_title}} was not confirmed in time, so we cancelled it and opened the time to other candidates.'),
    p('Still interested? Book another open time from your link.'),
    button('Book another time', '{{booking_url}}'),
  ],
  sample: { role_title: 'Customer Service Representative (Remote)', booking_url: 'https://carmacars.ca/careers/book/3f9a1c' },
};
