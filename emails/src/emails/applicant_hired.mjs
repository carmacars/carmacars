import { hero, p, steps, when, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'applicant_hired',
  audience: 'applicant',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'An Admin records Hire for a candidate after the interview call (Admin > Hiring, the candidate or the Calls tab) and sends the decision emails (Emails to send, Send all decision emails, now or at the time chosen; migration 0226). One email per candidate.',
  timing: 'When the Admin sends the decision emails',
  subject: 'Welcome to CarmaCars: your next steps',
  preheader: 'We would like you to join us as {{role_title}}.',
  ref: 'Careers',
  body: [
    hero('Careers', 'Welcome aboard, {{first_name}}', 'Thank you for the call. We would like you to join CarmaCars as {{role_title}}.'),
    p('Here is what happens next:'),
    steps('You get an email from CarmaCars to set up your staff account: choose a password from the link in it.',
      'Sign in and complete the CarmaCars Academy for your role (a few short lessons with a check at the end).',
      'We contact you to agree your start date and your first shifts.'),
    when('personal_note', p('{{personal_note}}')),
    small('Questions? Reply to this email and we will help.'),
  ],
  sample: { role_title: 'Sales and Customer Relations Coordinator (In person, Toronto)', personal_note: 'We loved your ideas for the dealership visits.' },
};
