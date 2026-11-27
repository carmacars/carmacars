import { hero, p, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'admin_call_cancelled',
  audience: 'staff_admin',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'R50 hotfix 2 (5150): a calendar cancellation of the weekly Admin call (an .ics file, METHOD:CANCEL) to a person who is no longer an Admin. Sent by the townhall job (app.admin_call_invites_sweep).',
  timing: 'Immediate, when the person is no longer an Admin',
  subject: '{{invite_subject}}',
  preheader: 'The weekly Admin call comes off your calendar.',
  ref: 'Admin call',
  body: [
    hero('Weekly Admin call', 'The Admin call is off your calendar', 'Hi {{first_name}}. You are no longer an Admin, so the weekly Admin call comes off your calendar.'),
    p('The attached cancellation takes it off your calendar when you open it.'),
    button('Open CarmaCars', '{{call_url}}'),
  ],
  sample: { invite_subject: 'Weekly Admin call: removed from your calendar', call_url: 'https://carmacars.ca/admin/admin-call/live' },
};
