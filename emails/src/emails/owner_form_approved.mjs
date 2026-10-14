import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_form_approved',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Customer service or an Admin approves a Form C or Form D the owner uploaded.',
  timing: 'Immediate',
  subject: '{{form_title}} approved',
  preheader: 'Thanks. Nothing more to do for this form.',
  ref: 'Owner documents',
  body: [
    hero('Form approved', 'Your form is approved', 'Thanks, {{first_name}}. {{form_title}} is on file. {{vehicle_line}}.'),
    button('View your documents', '@owner_documents'),
    small('Keep the paper original with your car records.'),
  ],
  sample: {
    form_title: 'Form D, limited power of attorney', vehicle_line: 'Covers every car you have with us',
  },
};
