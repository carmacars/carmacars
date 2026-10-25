import { hero, notice, button, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_recruit_outreach',
  audience: 'owner',
  category: 'marketing',
  from: FROM.owners,
  digest: false,
  trigger: 'An Admin sends a message to a prospective owner from Admin > Marketing > Owner recruitment (migration 0167). It is sent only when the consent log allows email for that person: express consent (a yes on a call, a form or a reply), implied consent from their inquiry (6 months) or a business relationship (2 years), a business address published with no "no solicitation" note, or one message after a referral. The message is a template the Admin may edit; the footer names CarmaCars, its mailing address and the reason for the email, and carries the unsubscribe link. One email per send.',
  timing: 'Immediate, when the Admin sends it',
  subject: '{{subject_line}}',
  preheader: 'A message from {{sender_name}} at CarmaCars about the owner program.',
  ref: 'Owner program',
  footer: 'You are receiving this because {{consent_reason}}.',
  body: [
    hero('Owner program', 'Hello {{first_name}}', '{{sender_name}} at CarmaCars wrote to you.'),
    notice('info', '{{subject_line}}', '{{message_body}}'),
    button('How the owner program works', '@list_your_car'),
    small('Reply to this email with any question. If you would rather not hear from us, use the unsubscribe link below and we will not write again.'),
  ],
  sample: {
    subject_line: 'Your 2021 Honda Civic and the CarmaCars owner program',
    message_body: 'As we discussed on the phone today, here are the details of the CarmaCars owner program. Your car goes on our fleet insurance policy, we rent it out in Toronto and pay you every month. Fees apply; the page below explains them.',
    sender_name: 'Priya',
    consent_reason: 'you agreed on a phone call to hear from CarmaCars about the owner program',
  },
};
