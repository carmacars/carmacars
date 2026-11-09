import { hero, p, button, small, list } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_agreement_reminder',
  audience: 'staff_field',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'A staff member\'s staff agreement has waited 3 days for their signature (migration 1060). Sent once to that staff member. The agreement opens for signing once their academy is passed.',
  timing: '3 days after the agreement was sent, once',
  subject: 'Reminder: please sign your CarmaCars staff agreement',
  preheader: 'It takes a few minutes, in your staff portal.',
  ref: 'Staff agreement',
  body: [
    hero('Staff agreement', 'Your agreement is waiting', 'Hi {{first_name}}. Your staff agreement is ready in your portal and still needs your signature.'),
    list(
      'Pass the academy first: the agreement opens for signing once every section is passed.',
      'Read it, then sign on screen. You get a copy by email.',
      'The rest of your portal opens once it is signed.',
    ),
    button('Open my documents to sign', '{{sign_url}}'),
    small('Questions about the agreement? Reply to this email before you sign.'),
  ],
  sample: { sign_url: 'https://carmacars.ca/staff/sign' },
};
