import { hero, facts, button, when, p } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'applicant_reminder',
  audience: 'applicant',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'A booked interview call is the next day (sent at 6 pm Toronto time the evening before) or about an hour away (migration 0173, app.job_hiring every 15 minutes). Not sent when the call was booked after that moment. When phone and texts are on, a text goes with the reminder an hour before. One email per reminder.',
  timing: 'The evening before (6 pm Toronto time) and about an hour before the call',
  subject: 'Reminder: your CarmaCars interview call is {{when_text}}',
  preheader: '{{call_when}}, Toronto time.',
  ref: 'Careers',
  body: [
    hero('Careers', 'See you {{when_text}}, {{first_name}}', 'Your interview call for {{role_title}}.'),
    facts(
      ['When (Toronto time)', '{{call_when}}'],
      { label: 'In Manila', value: '{{call_when_manila}}', when: 'call_when_manila' },
      ['Length', 'About {{call_minutes}} minutes'],
    ),
    when('is_video', p('Video call: {{meet_url}}'), p('We will call you at {{phone_display}}.')),
    button('Move or cancel the call', '{{manage_url}}'),
  ],
  sample: {
    role_title: 'Sales and Customer Relations Coordinator (In person, Toronto)', when_text: 'tomorrow', call_when: 'Thursday, October 29 at 2:40 pm', call_when_manila: '', call_minutes: '15',
    is_video: true, meet_url: 'https://meet.jit.si/CarmaCars-4c1e9a0b7d2f6e13', phone_display: '416-555-0142', manage_url: 'https://carmacars.ca/careers/book/3f9a1c',
  },
};
