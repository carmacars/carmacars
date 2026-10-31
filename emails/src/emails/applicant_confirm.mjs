import { hero, p, button, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'applicant_confirm',
  audience: 'applicant',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'A candidate for a remote role has a video interview call booked: 24 hours before it (or at once when the call is booked less than 24 hours ahead), the hiring job asks them to confirm (migration 0229). Remote roles get no reminder emails or texts: this is the only one. One email per booking.',
  timing: '24 hours before the call',
  subject: 'Please confirm your CarmaCars interview call, {{call_when}}',
  preheader: 'One click keeps your call. Unconfirmed calls are cancelled.',
  ref: 'Careers',
  body: [
    hero('Careers', 'Please confirm your call, {{first_name}}', 'Your video interview call for {{role_title}} is {{call_when}} Toronto time ({{call_when_manila}} in Manila).'),
    button('Confirm my call', '{{confirm_url}}'),
    p('Please confirm by {{confirm_by}}. A call that is not confirmed by then is cancelled, so another candidate can have the time.'),
    p('At the time of the call, join the video call: {{meet_url}}'),
    small('Need another time? Change it from your link: {{manage_url}}'),
  ],
  sample: { role_title: 'Customer Service Representative (Remote)', call_when: 'Tuesday, November 3 at 9:00 am', call_when_manila: 'Tuesday, November 3 at 10:00 pm',
    confirm_url: 'https://carmacars.ca/careers/book/3f9a1c/confirm?seq=1', confirm_by: 'Monday, November 2 at 9:00 pm Toronto time',
    meet_url: 'https://meet.jit.si/CarmaCars-3f9a1c', manage_url: 'https://carmacars.ca/careers/book/3f9a1c' },
};
