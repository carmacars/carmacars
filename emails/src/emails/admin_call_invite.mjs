import { hero, p, small, facts, button, when } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'admin_call_invite',
  audience: 'staff_admin',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'R50 hotfix 2 (5150): the weekly Admin call calendar invite (an .ics file, METHOD:REQUEST, repeating every week, Toronto time) to every active Admin: once when they become an Admin, and again as an update whenever the day, the time or the length changes (Admin call page or Program settings). Sent by the townhall job (app.admin_call_invites_sweep).',
  timing: 'Immediate: on becoming an Admin, and on every change of the day, time or length',
  subject: '{{invite_subject}}',
  preheader: '{{call_when}}, {{call_minutes}} minutes. Open the invite to add it to your calendar.',
  ref: 'Admin call',
  body: [
    hero('Weekly Admin call', '{{invite_title}}', 'Hi {{first_name}}. The weekly Admin call is in the attached calendar invite: accept it once and it repeats every week in your calendar.'),
    facts(
      ['When', '{{call_when}}'],
      ['Length', '{{call_minutes}} minutes'],
      ['Where', 'In the Admin portal: Admin call, Join the call'],
    ),
    when('is_update', p('This replaces the invite you had: your calendar moves the call by itself once you open it.')),
    button('Open the Admin call', '{{call_url}}'),
    small('The deck builds itself before each call from the live data, with Approve and Deny on every decision to take.'),
  ],
  sample: { invite_subject: 'Weekly Admin call: your calendar invite', invite_title: 'Your Admin call invite', call_when: 'Every Sunday at 7:00 pm Toronto time',
    call_minutes: '60', is_update: false, call_url: 'https://carmacars.ca/admin/admin-call/live' },
};
