import { hero, p, button, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'applicant_new_times',
  audience: 'applicant',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'An Admin adds or opens an interview day for a role (Admin > People > Hiring) and a candidate invited for that role had found no open call times on their booking link (migration 0211). One email per candidate per day added.',
  timing: 'Immediate',
  subject: 'New times are open for your CarmaCars interview call',
  preheader: 'Pick a time on {{call_days}}.',
  ref: 'Careers',
  body: [
    hero('Careers', 'New times are open, {{first_name}}', 'We opened new interview call times for {{role_title}}.'),
    p('Pick any open time on {{call_days}}. The call takes about {{call_minutes}} minutes. You can move or cancel it from the same link.'),
    button('Book my interview call', '{{booking_url}}'),
    small('The link is personal: please do not share it. If no time suits you, reply to this email.'),
  ],
  sample: { role_title: 'Field Staff: Driver and Detailer', call_days: 'Thursday, November 5', call_minutes: '15', booking_url: 'https://carmacars.ca/careers/book/3f9a1c' },
};
