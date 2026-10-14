import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_owner_form_uploaded',
  audience: 'staff_va_cs',
  category: 'transactional',
  from: FROM.owners,
  digest: true,
  digestSlot: 'next',
  trigger: 'An owner uploads a signed and witnessed Form C (lender or lessor permission acknowledgment, per financed or leased car) or Form D (limited power of attorney). Queued for the next customer service digest; a review task is raised with it.',
  timing: 'Next digest',
  subject: 'Review {{form_title}} from {{owner_name}}',
  preheader: 'Signed with witnesses {{witness_names}}.',
  ref: '{{owner_name}}',
  body: [
    hero('Form uploaded', '{{owner_name}} uploaded a signed form', '{{form_title}}. {{vehicle_line}}.'),
    facts(
      ['Witnesses', '{{witness_names}}'],
    ),
    button('Review the form', '@va_owner_forms'),
    small('Check every part is filled, initialled where asked, signed and witnessed. Approve it, or send it back with what to fix.'),
  ],
  sample: {
    owner_name: 'Daniel Rossi', form_title: 'Form C, lender or lessor permission acknowledgment', vehicle_line: 'For your 2023 Toyota RAV4 XLE',
    witness_names: 'Wendy Clark',
  },
};
