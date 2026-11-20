import { hero, notice, button, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'text_fell_back',
  audience: 'renter',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'A text CarmaCars meant to send could not go (the texting service refused it, for example when its prepaid credits ran out) and the person has an email address: the same words come by email instead, once, and the text is marked "not sent: fell back to email" (release 48, migration 3110). A text whose own email already went, or that is no longer relevant, is never sent this way.',
  timing: 'Immediate, once per text',
  subject: 'A message from CarmaCars',
  preheader: '{{message_body}}',
  ref: 'Message',
  body: [
    hero('Message', 'A message from CarmaCars', 'Hello {{first_name}}. We tried to text you this, and it did not go through, so here it is by email.'),
    notice('info', 'Our message', '{{message_body}}'),
    button('Open carmacars.ca', '@home'),
    small('Reply to this email or call us if you have a question.'),
  ],
  sample: { message_body: 'Hi Maya, a reminder that your CarmaCars pickup for CC-10482 is tomorrow, Sat Nov 21 at 10:00 am. Details: carmacars.ca/trips' },
};
