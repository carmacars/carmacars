import { hero, p, facts, button, list, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_resignation_received',
  audience: 'staff_admin',
  also: ['staff_va_finance'],
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'Release 50 (5020): a staff member resigned in their portal, or an Admin recorded a resignation. To the Admins, and to Finance for the final pay. An offboarding To do opens at the same time (one per resignation).',
  timing: 'Immediate, once per resignation',
  subject: 'Resignation: {{staff_name}}, last day {{last_day}}',
  preheader: '{{role_label}}. Final pay up to the last day; the offboarding To do is open.',
  ref: 'Staff {{staff_name}}',
  body: [
    hero('Staff', '{{staff_name}} resigned', '{{staff_name}} ({{role_label}}) gave notice on {{resigned_on}}.'),
    facts(
      ['Last day', '{{last_day}}'],
      ['Notice', '{{notice_text}}'],
      ['Reason', '{{reason}}'],
      ['Recorded by', '{{recorded_by}}'],
    ),
    p('{{handover_text}}'),
    list(
      'Finance: {{final_pay_text}}',
      'Collect every key, fob, fuel or company card and item of equipment they have.',
      'Reassign their open field jobs and shifts, and hand back their leads, chats and To dos.',
      'Their access ends by itself after the last day. Change the last day or end access now on Staff and roles.',
    ),
    button('Open Staff and roles', '{{admin_url}}'),
    small('The offboarding To do lists all of this with the numbers, under To do and Staff tasks.'),
  ],
  sample: { staff_name: 'Sam Example', role_label: 'Field staff', resigned_on: 'Wed, Nov 25, 2026', last_day: 'Wed, Dec 2, 2026', notice_text: '7 days (7 asked)',
    reason: 'Moving to another city', recorded_by: 'Themselves, in their portal',
    handover_text: 'Went back to the queue after the last day: 2 field jobs and 3 shifts. Still theirs: 4 open jobs, 0 leads, 1 chats, 2 To dos.',
    final_pay_text: 'Every hour worked up to Wed, Dec 2, 2026, with vacation pay, on the pay date of the period that ends Sat, Dec 5, 2026.',
    admin_url: 'https://carmacars.ca/admin/settings/staff#resign-3f1c7a2e' },
};
