import { hero, p, button, small, when } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'applicant_ai_interview',
  audience: 'applicant',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'A candidate for a remote assistant role (customer service, fleet, finance or remote sales) passes screening, or an Admin presses Invite anyway or New interview link in Admin > People > Hiring, while AI interviews are on (migration 0380): the personal link to the recorded interview they take on their own, instead of the link to book a live call. In-person roles keep their calls. One email per link; no reminders and no texts. Since migration 2680 an Admin can also redo a hired or interviewed applicant\'s interview (Admin > People > Hiring > the candidate > Redo the AI interview): the same email with a friendly explanation that the role needs the recorded video interview.',
  timing: 'Immediate',
  subject: 'CarmaCars: your interview for {{role_title}}',
  preheader: 'About {{minutes}} minutes, whenever suits you before {{expires_on}}.',
  ref: 'Careers',
  body: [
    hero('Careers', 'Let\'s talk, {{first_name}}', 'Thank you for applying for {{role_title}}. Your answers stood out, and the next step is a short interview.'),
    p('You do it on your own, at any time that suits you, from your phone or computer: {{question_count}} questions, about {{minutes}} minutes. Each question is shown and read aloud, and you answer on video, out loud, to your camera. You need a phone or computer with a camera and a microphone.'),
    when('redo', p('**Why you are getting this link:** this role needs a recorded video interview, and we would like you to take it before going further. Please record it with the link below. Your access to the team portal is on hold until then. Thank you for your patience, we are glad to have you.')),
    button('Start my interview', '{{interview_url}}'),
    p('The link works until {{expires_on}}. Find a quiet place with a good connection; you can stop and come back to it with the same link.'),
    small('The interview is recorded so our hiring team can listen to your answers; a person makes every decision. The link is personal: please do not share it. Questions? Reply to this email.'),
  ],
  sample: { role_title: 'Customer Service Coordinator (Remote)', interview_url: 'https://carmacars.ca/careers/interview/3f9a1c', expires_on: 'Saturday, November 14',
    question_count: '9', minutes: '10', redo: true },
};
