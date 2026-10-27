import { hero, p, when, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'applicant_declined',
  audience: 'applicant',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'A candidate\'s answers on carmacars.ca/careers include a knock-out (a requirement of the role they do not meet) and the role offers no other role instead, or an Admin presses Decline in Admin > People > Hiring with the email left on (migration 0173). One email per decision.',
  timing: 'Immediate',
  subject: 'Your CarmaCars application',
  preheader: 'Thank you for applying for {{role_title}}.',
  ref: 'Careers',
  body: [
    hero('Careers', 'Thank you, {{first_name}}', 'Thank you for applying for {{role_title}} at CarmaCars.'),
    when('decline_reason', p('This role needs {{decline_reason}}, so we cannot move forward this time.'), p('We have decided not to move forward with your application this time.')),
    p('We wish you the best, and we hope you will apply again for a future role.'),
    button('See our open roles', '@careers'),
  ],
  sample: { role_title: 'Finance and Billing Coordinator (Remote)', decline_reason: 'the code word from the job post' },
};
