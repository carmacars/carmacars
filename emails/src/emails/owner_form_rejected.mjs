import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_form_rejected',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Customer service or an Admin sends back a Form C or Form D the owner uploaded, with the reason. The owner uploads it again from the owner portal.',
  timing: 'Immediate',
  subject: 'Please upload {{form_title}} again',
  preheader: '{{reject_reason}}',
  ref: 'Owner documents',
  body: [
    hero('Form sent back', 'One thing to fix on your form', '{{form_title}}. {{vehicle_line}}.'),
    notice('alert', 'What to fix', '{{reject_reason}}'),
    button('Upload it again', '@owner_documents'),
    small('Sign with your witnesses again where needed, then upload a clear photo or scan of every page.'),
  ],
  sample: {
    form_title: 'Form C, lender or lessor permission acknowledgment', vehicle_line: 'For your 2023 Toyota RAV4 XLE',
    reject_reason: 'The witness did not sign next to the third set of initials.',
  },
};
