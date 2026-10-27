import { hero, p, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'applicant_cancelled',
  audience: 'applicant',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'A candidate cancels their interview call from their booking link on carmacars.ca/careers/book (migration 0173). The invitation stays open: the same link books another time. One email per cancellation.',
  timing: 'Immediate',
  subject: 'Your CarmaCars interview call is cancelled',
  preheader: 'You can book another time from the same link.',
  ref: 'Careers',
  body: [
    hero('Careers', 'Your call is cancelled, {{first_name}}', 'We cancelled your interview call for {{role_title}}, as you asked.'),
    p('Changed your mind? Book another open time from your link.'),
    button('Book another time', '{{booking_url}}'),
  ],
  sample: { role_title: 'Field Staff: Driver and Detailer', booking_url: 'https://carmacars.ca/careers/book/3f9a1c' },
};
