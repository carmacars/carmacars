import { hero, p, small, button, facts, notice, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_invoice_voided',
  audience: 'owner',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'An Admin voids an issued owner invoice with a reason (nothing was paid on it). Its scheduled debit is cancelled. When a corrected invoice replaces it, that invoice has its own email once it is issued. One email per owner per day (migration 0900): the email waits a short while (Program settings, 30 minutes by default) and every invoice voided for the same owner meanwhile is listed in it; once the day\'s email went, the next voids wait for the next morning\'s email.',
  timing: 'Within 30 minutes, one email per owner per day',
  subject: '{{voided_title}}',
  preheader: '{{voided_preheader}}',
  ref: '{{voided_ref}}',
  body: [
    hero('Invoice cancelled', '{{voided_heading}}', 'Hi {{first_name}}, {{voided_lead}}'),
    when('has_several', [
      each('invoices', [p('**Invoice {{invoice_number}}** ({{invoice_total}}, {{vehicle_name}}): {{void_reason}}{{#if replacement_number}} Replaced by invoice {{replacement_number}}.{{/if}}')]),
      p('Nothing will be debited for them. A replacement invoice has its own email once it is ready.'),
    ], [
      facts(['Invoice no.', '{{invoice_number}}'], ['Amount', '{{invoice_total}}'], ['Vehicle', '{{vehicle_name}}']),
      notice('info', 'Why', '{{void_reason}}'),
      p('Nothing will be debited for it.'),
      when('has_replacement', [p('It is replaced by invoice {{replacement_number}}, with the correct amount. We send it to you when it is ready.')]),
    ]),
    button('View my invoices', '@owner_invoices'),
    small('Questions? Reply to this email.'),
  ],
  sample: {
    invoice_number: 'INV-1046', invoice_total: '$904.00', vehicle_name: '2023 Toyota RAV4 XLE',
    void_reason: 'The first and last month amount we agreed is $800.00, not $904.00.', has_replacement: true, replacement_number: 'INV-1053',
    voided_title: 'Invoice INV-1046 is cancelled', voided_preheader: 'The first and last month amount we agreed is $800.00, not $904.00.', voided_ref: 'Invoice INV-1046',
    voided_heading: 'You do not need to pay invoice INV-1046', voided_lead: 'we cancelled this invoice for your 2023 Toyota RAV4 XLE.', has_several: false,
    invoices: [{ invoice_number: 'INV-1046', invoice_total: '$904.00', vehicle_name: '2023 Toyota RAV4 XLE', void_reason: 'The first and last month amount we agreed is $800.00, not $904.00.', replacement_number: 'INV-1053' }],
  },
};
