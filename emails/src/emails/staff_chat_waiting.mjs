import { hero, facts, button, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_chat_waiting',
  audience: 'staff_va_cs',
  also: ['staff_va_sales', 'staff_admin'],
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'A visitor in live chat needs a person (they asked, or the assistant handed over: a complaint, damage, an accident, a payment, a question it could not answer, or the day\'s AI allowance is used). Sent only to staff on shift (Live chat or Live visitors open in the last minutes) who turned on "Email me when a chat waits" in Live chat. Immediate.',
  timing: 'Immediate',
  subject: 'Live chat {{chat_number}} waits for you: {{visitor_name}}',
  preheader: '{{chat_reason}}. Reply within the first reply target.',
  ref: 'Live chat {{chat_number}}',
  body: [
    hero('Live chat', 'A visitor is waiting for a person', '{{visitor_name}} needs a reply in live chat. The assistant has stopped answering this conversation.'),
    facts(
      ['Chat', '{{chat_number}}'],
      ['Why', '{{chat_reason}}'],
      ['Page', '{{chat_page}}'],
    ),
    button('Open Live chat', '{{chat_url}}'),
    small('You get this email because you turned on "Email me when a chat waits" in Live chat and you are on shift. Turn it off there.'),
  ],
  sample: {
    chat_number: 'LC-1042', visitor_name: 'Visitor from Toronto, phone', chat_reason: 'asked for a person', chat_page: 'Car page',
    chat_url: 'https://carmacars.ca/staff/chat',
  },
};
