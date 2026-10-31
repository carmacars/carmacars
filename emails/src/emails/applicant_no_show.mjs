import { hero, p, button, when, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'applicant_no_show',
  audience: 'applicant',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'An Admin records No show for a candidate who missed the interview call (Admin > Hiring) with the email on, and sends the decision emails (Emails to send, Send all decision emails, now or at the time chosen; migration 0226). One email per candidate.',
  timing: 'When the Admin sends the decision emails',
  subject: 'We missed you on the CarmaCars call',
  preheader: 'Your interview call for {{role_title}} did not take place.',
  ref: 'Careers',
  body: [
    hero('Careers', 'We missed you, {{first_name}}', 'We were ready for your interview call for {{role_title}}, but we could not reach you.'),
    p('We understand that things come up. We have closed this application for now.'),
    when('personal_note', p('{{personal_note}}')),
    p('If you are still interested, you are welcome to apply again for any of our open roles.'),
    button('See our open roles', '@careers'),
    small('Thank you for your interest in CarmaCars.'),
  ],
  sample: { role_title: 'Remote Sales Coordinator (Commission only, worldwide)', personal_note: '' },
};
