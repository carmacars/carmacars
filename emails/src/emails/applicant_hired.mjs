import { hero, p, steps, button, when, small } from '../components.mjs';
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
    p('Here is what happens next. You are not working a shift right away: this gives you access to the staff portal, where you do your training and claim your shifts online.'),
    steps(['Set up your account', 'You get an email from CarmaCars to set up your staff account: choose a password from the link in it.'],
      ['Do your training', 'Sign in and complete the CarmaCars Academy for your role (a few short lessons with a check at the end).'],
      ['Claim your shifts', 'Claim your shifts online in the portal. You pick the shifts that suit you; you do not have to take a particular first shift.'],
      ['Say hello to the team', 'Once you are hired, send a message in the team chat (the CarmaCars Team WhatsApp group, the link is in your portal). In each WhatsApp group, set your member tag as "Name - Position", for example "Maria - Sales".']),
    button('Open the staff portal', '@va_cs'),
    when('personal_note', p('{{personal_note}}')),
    small('Questions? Reply to this email and we will help.'),
  ],
  sample: { role_title: 'Sales and Customer Relations Coordinator (In person, Toronto)', personal_note: 'We loved your ideas for the dealership visits.' },
};
