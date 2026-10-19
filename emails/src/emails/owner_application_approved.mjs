import { hero, p, small, h, button, steps, when } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_application_approved',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'An Admin approves an owner application the owner sent themselves (Admin > Owners and partners > Applications > Approve): the owner is active, each car has the terms the Admin confirmed, the agreements open for one signature in the owner portal, and only the invoices the Admin chose are sent (their own emails go too). An application staff entered for the owner gets owner_car_set_up instead.',
  timing: 'Immediate',
  subject: 'Approved: your {{vehicle_name}} can join CarmaCars',
  preheader: 'Sign your documents and pay the first invoice in your owner portal.',
  ref: 'Owner application {{application_number}}',
  body: [
    hero('Application approved', 'Welcome to CarmaCars, {{first_name}}', 'We approved application {{application_number}} for your {{vehicle_name}}.'),
    h('What happens next'),
    steps(
      ['Sign your documents', 'Your agreements are filled in from your application. Check the key values and sign them all with one signature in your owner portal.'],
      ['Pay the first invoice', 'When we send it: the first and last month amount we agreed. You can pay by card, pre-authorized debit or e-Transfer from the invoice page.'],
      ['We book the registry visit', 'We email you the date and what to bring.'],
    ),
    when('invoice_count', [p('Your first invoice is in your owner portal, and we sent it to you in a separate email.')]),
    button('Open my owner portal', '@owner'),
    small('Questions about your terms? Reply to this email before you sign.'),
  ],
  sample: { application_number: 'OA-1001', vehicle_name: '2023 Toyota RAV4 XLE', invoice_count: 1 },
};
