import { hero, p, small, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'applicant_received',
  audience: 'applicant',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'A candidate sends an application on carmacars.ca/careers and the screening score is below the role\'s pass mark, with no knock-out and no other open role to offer (migration 0173). The application waits for the owner\'s review. One email per application; invited, declined and referred candidates get their own email instead.',
  timing: 'Immediate',
  subject: 'We have your application: {{role_title}}',
  preheader: 'Thank you for applying to CarmaCars. A person reads every application.',
  ref: 'Careers',
  body: [
    hero('Careers', 'Thank you, {{first_name}}', 'We have your application for {{role_title}}.'),
    p('A person at CarmaCars reads every application. If your experience fits what we need, we will write to you with a time to talk. You do not need to do anything now.'),
    button('See our open roles', '@careers'),
    small('If you did not apply, you can ignore this email.'),
  ],
  sample: { role_title: 'Field Staff: Driver and Detailer' },
};
