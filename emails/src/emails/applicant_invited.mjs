import { hero, p, button, notice, when, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'applicant_invited',
  audience: 'applicant',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'A candidate\'s screening score on carmacars.ca/careers reaches the role\'s pass mark with no knock-out, or an Admin presses Invite anyway in Admin > People > Hiring (migration 0173). The email has the candidate\'s personal booking link for a short interview call; for a remote assistant role it also describes the paid test task. One email per invitation.',
  timing: 'Immediate',
  subject: 'CarmaCars: book your {{call_minutes}}-minute interview call',
  preheader: 'Pick a time on {{call_days}} that suits you.',
  ref: 'Careers',
  body: [
    hero('Careers', 'Let\'s talk, {{first_name}}', 'Thank you for applying for {{role_title}}. Your answers stood out and we would like a short call.'),
    p('Pick any open time on {{call_days}}. The call takes about {{call_minutes}} minutes. You can move or cancel it from the same link.'),
    button('Book my interview call', '{{booking_url}}'),
    when('test_task', notice('info', 'After the call: a paid test', '{{test_task}}')),
    small('The link is personal: please do not share it. If no time suits you, reply to this email.'),
  ],
  sample: {
    role_title: 'Field Staff: Driver and Detailer', call_days: 'Thursday, October 29', call_minutes: '15',
    booking_url: 'https://carmacars.ca/careers/book/3f9a1c', test_task: '',
  },
};
