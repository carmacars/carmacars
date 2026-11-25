import { hero, p, h, small, facts, button, when } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_resignation_confirmed',
  audience: 'staff_field',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'Release 50 (5020): a staff member resigned in their portal (My profile, Resign), or an Admin recorded their resignation. Sent again, as an update, when an Admin changes the last day. Covers the final pay timing from their agreement or pay settings, what to return, and how to withdraw until the last day.',
  timing: 'Immediate, on resigning and on a new last day',
  subject: 'Your resignation: last day {{last_day}}',
  preheader: 'What happens next: your final pay, what to return, and how to withdraw.',
  ref: 'Staff account',
  body: [
    hero('Staff account', 'We received your resignation', 'Hi {{first_name}}. Thank you for your work with CarmaCars. Here is what happens next.'),
    when('is_update', p('An Admin changed your last day. This email replaces the one you had before.')),
    facts(
      ['Last day', '{{last_day}}'],
      ['Resigned on', '{{resigned_on}}'],
      ['Your access ends', '{{access_ends}}'],
    ),
    h('Your final pay'),
    p('{{final_pay_text}}'),
    h('Return what belongs to CarmaCars'),
    p('{{return_text}}'),
    h('Changed your mind?'),
    p('{{withdraw_text}}'),
    when('can_withdraw', button('Open my profile', '{{profile_url}}')),
    small('Questions about your last day or your final pay: reply to this email.'),
  ],
  sample: { last_day: 'Wed, Dec 2, 2026', resigned_on: 'Wed, Nov 25, 2026', access_ends: 'At the end of Wed, Dec 2, 2026', is_update: false, can_withdraw: true,
    final_pay_text: 'Every hour you work up to Wed, Dec 2, 2026, with your vacation pay and any commission earned, is paid on the pay date of the pay period that ends Sat, Dec 5, 2026 (you are paid every two weeks), within the time Ontario\'s Employment Standards Act requires (Field Staff Agreement 9.4).',
    return_text: 'Return every key, fob, fuel or company card and item of equipment you have on or before your last day, and within 7 days return or delete any CarmaCars information on your own devices.',
    withdraw_text: 'Changed your mind? Open your profile and press Withdraw my resignation, any time up to Wed, Dec 2, 2026.',
    profile_url: 'https://carmacars.ca/staff/field/profile#resign' },
};
