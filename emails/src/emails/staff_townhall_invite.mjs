import { hero, p, small, facts, button, when } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_townhall_invite',
  audience: 'staff_field',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'Release 50 (5000): the weekly townhall calendar invite (an .ics file, METHOD:REQUEST, repeating every week, Toronto time) to every staff member and Admin: once when they join the team, and again as an update whenever an Admin changes the day, the time or the length, or puts a cancelled townhall back on. Sent by the townhall job (app.townhall_invites_sweep).',
  timing: 'Immediate: on joining the team, and on every change of the day or time',
  subject: '{{invite_subject}}',
  preheader: '{{townhall_when}}, {{townhall_minutes}} minutes. Open the invite to add it to your calendar.',
  ref: 'Townhall',
  body: [
    hero('Weekly townhall', '{{invite_title}}', 'Hi {{first_name}}. The weekly CarmaCars townhall is in the attached calendar invite: accept it once and it repeats every week in your calendar.'),
    facts(
      ['When', '{{townhall_when}}'],
      ['Length', '{{townhall_minutes}} minutes'],
      ['Where', 'In the staff portal: Townhall, Join the call'],
    ),
    when('is_update', p('This replaces the invite you had: your calendar moves the townhall by itself once you open it.')),
    button('Open the townhall', '{{call_url}}'),
    small('Every staff member is expected, cameras on. Joining through the portal counts your attendance; two townhalls missed in a row lock your account until an Admin restores it.'),
  ],
  sample: { invite_subject: 'Weekly townhall: your calendar invite', invite_title: 'Your townhall invite', townhall_when: 'Every Wednesday at 1:00 pm Toronto time',
    townhall_minutes: '45', is_update: false, call_url: 'https://carmacars.ca/staff/townhall/live' },
};
