import { hero, p, button, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'applicant_ai_interview_sorry',
  audience: 'applicant',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'Once, by migration 0534 (the owner, November 6, 2026): a candidate for a remote assistant role (customer service, fleet, finance or remote sales) who was invited to book a call, or whose booked call time passed without the call, is moved to the AI interview: an apology for the scheduling problem on our side and the personal link to the recorded interview. No booking needed.',
  timing: 'Once',
  subject: 'CarmaCars: sorry about the interview times, here is your interview link',
  preheader: 'No need to book a call: do the short recorded interview any time before {{expires_on}}.',
  ref: 'Careers',
  body: [
    hero('Careers', 'Sorry about the scheduling, {{first_name}}', 'Thank you for applying for {{role_title}}. We had a scheduling problem on our side with the interview calls, and we are sorry for the trouble.'),
    p('There is no need to book a call. Instead, do the short recorded interview any time this week, from your phone or computer: {{question_count}} questions, about {{minutes}} minutes. Each question is shown and read aloud, and you answer out loud, or type if you prefer.'),
    button('Start my interview', '{{interview_url}}'),
    p('The link works until {{expires_on}}. You can stop and come back to it with the same link.'),
    small('The interview is recorded so our hiring team can listen to your answers; a person makes every decision. The link is personal: please do not share it. Questions? Reply to this email.'),
  ],
  sample: { role_title: 'Customer Service Coordinator (Remote)', interview_url: 'https://carmacars.ca/careers/interview/3f9a1c', expires_on: 'Friday, November 13',
    question_count: '9', minutes: '10' },
};
