import { hero, p, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_resignation_withdrawn',
  audience: 'staff_admin',
  also: ['staff_va_finance'],
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'Release 50 (5020): a staff member withdrew their resignation before the last day (or an Admin withdrew it for them). To the Admins and Finance; the offboarding To do closes by itself.',
  timing: 'Immediate',
  subject: '{{staff_name}} withdrew their resignation',
  preheader: 'They stay on the team. The offboarding To do is closed.',
  ref: 'Staff {{staff_name}}',
  body: [
    hero('Staff', 'Resignation withdrawn', '{{staff_name}} ({{role_label}}) is staying. The resignation had their last day on {{last_day}}.'),
    p('Withdrawn by: {{withdrawn_by}}. The offboarding To do is closed and no final pay is due.'),
    p('Field jobs and shifts after the old last day went back to the queue when they resigned and stay there: assign them again if needed.'),
    button('Open Staff and roles', '{{admin_url}}'),
  ],
  sample: { staff_name: 'Sam Example', role_label: 'Field staff', last_day: 'Wed, Dec 2, 2026', withdrawn_by: 'Themselves, in their portal',
    admin_url: 'https://carmacars.ca/admin/settings/staff#resign-3f1c7a2e' },
};
