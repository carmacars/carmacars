import { hero, p, facts, button, when } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_townhall_cancelled',
  audience: 'staff_field',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'Release 50 (5000): a calendar cancellation (an .ics file, METHOD:CANCEL). One townhall: an Admin cancels it ahead (Townhall > Meetings), to every staff member and Admin who has the weekly invite. The whole series: the person is no longer on the team. Sent by the townhall job (app.townhall_invites_sweep).',
  timing: 'Immediate, when a townhall is cancelled or the person leaves the team',
  subject: '{{cancel_subject}}',
  preheader: '{{cancel_lead}}',
  ref: 'Townhall',
  body: [
    hero('Weekly townhall', '{{cancel_title}}', 'Hi {{first_name}}. {{cancel_lead}}'),
    when('meeting_when', facts(['Cancelled', '{{meeting_when}}'], { label: 'Why', value: '{{reason}}', when: 'reason' })),
    p('The attached cancellation takes it off your calendar when you open it.'),
    when('is_series', p('You no longer have the weekly townhall in your calendar.'), button('Open the townhall', '{{call_url}}')),
  ],
  sample: { cancel_subject: 'Townhall cancelled: Wednesday, December 2', cancel_title: 'This week\'s townhall is cancelled', cancel_lead: 'The townhall of Wednesday, December 2 at 1:00 pm is cancelled. The next one is on as usual.',
    meeting_when: 'Wednesday, December 2 at 1:00 pm', reason: 'Public holiday', is_series: false, call_url: 'https://carmacars.ca/staff/townhall' },
};
