import { hero, facts, button, when, p, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'applicant_booked',
  audience: 'applicant',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'A candidate books, or moves, their interview call from their booking link on carmacars.ca/careers/book (migration 0173). By phone, CarmaCars calls the number on the application; by video, the email has the Jitsi Meet link made for this booking. One email per booking or move.',
  timing: 'Immediate',
  subject: '{{#if rescheduled}}Moved: {{/if}}your CarmaCars interview call, {{call_when}}',
  preheader: 'Toronto time. {{call_minutes}} minutes.',
  ref: 'Careers',
  body: [
    hero('Careers', 'You are booked, {{first_name}}', 'Your interview call for {{role_title}}.'),
    facts(
      ['When (Toronto time)', '{{call_when}}'],
      { label: 'In Manila', value: '{{call_when_manila}}', when: 'call_when_manila' },
      ['Length', 'About {{call_minutes}} minutes'],
    ),
    when('is_video', p('It is a video call. Open this link a minute before the time, in a browser or the Jitsi Meet app: {{meet_url}}'),
      p('We will call you at {{phone_display}}. Please be somewhere quiet with good reception.')),
    button('Move or cancel the call', '{{manage_url}}'),
    small('We send a reminder the evening before and an hour before.'),
  ],
  sample: {
    role_title: 'Field Staff: Driver and Detailer', call_when: 'Thursday, October 29 at 10:20 am', call_when_manila: '', call_minutes: '15',
    is_video: false, meet_url: '', phone_display: '416-555-0142', manage_url: 'https://carmacars.ca/careers/book/3f9a1c', rescheduled: false,
  },
};
