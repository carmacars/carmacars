import { hero, p, button, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'applicant_ai_interview_reminder',
  audience: 'applicant',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'An applicant invited to the recorded AI interview has not finished it (r50 hotfix 2, migration 5161): a reminder with the one-tap link, a day after the link was sent, three days after, and the day before it expires (Program settings hiring_ai_reminder_hours). None once the interview is sent in, the link has expired or another email to the applicant is still waiting to go. A text goes with it to a Canadian or US number while texts are on.',
  timing: '1 day and 3 days after the interview link, and 1 day before it expires',
  subject: 'Reminder: your CarmaCars interview for {{role_title}}',
  preheader: 'One tap starts it. About {{minutes}} minutes, before {{expires_on}}.',
  ref: 'Careers',
  body: [
    hero('Careers', 'Your interview is waiting, {{first_name}}', 'You applied for {{role_title}} and your interview is still open. It takes about {{minutes}} minutes, from your phone or computer.'),
    button('Start my interview now', '{{interview_url}}'),
    p('{{answered_line}} The link works until {{expires_on}}. You need a camera and a microphone, a quiet place and a good connection.'),
    small('If the link has expired when you open it, the page lets you open a new one and start straight away. The link is personal: please do not share it.'),
  ],
  sample: { role_title: 'Customer Service Coordinator (Remote)', interview_url: 'https://carmacars.ca/careers/interview/3f9a1c', expires_on: 'Saturday, November 14',
    minutes: '10', answered_line: 'You have answered 2 of 9 questions: it picks up where you left off.' },
};
