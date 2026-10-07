import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_document_due',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Expiry-watch job (daily 06:00): a document or registration item on the owner\'s vehicle expires in 14 days: plate renewal, or for a Turo-Only vehicle the owner\'s insurance proof. Sent once at 14 days and again at 3 days if still open. (Message template T23 for Turo-Only insurance.)',
  timing: '14 days before the expiry, again at 3 days',
  source: 'T23',
  subject: '{{document_type}} for your {{vehicle_name}} is due {{due_date}}',
  preheader: '{{document_action_short}}',
  ref: 'Document due',
  body: [
    hero('Document due', '{{document_type}} is due {{due_date}}', 'A date is coming up on your {{vehicle_name}}, {{first_name}}.'),
    facts(
      ['Vehicle', '{{vehicle_name}}, plate {{vehicle_plate}}'],
      ['Item', '{{document_type}}'],
      ['Expires', '{{due_date}}'],
    ),
    notice('alert', 'What you need to do', '{{document_action}}'),
    button('Upload or review documents', '@owner_documents'),
    small('{{document_consequence}}'),
  ],
  sample: {
    document_type: 'Insurance proof', due_date: 'Sat, Nov 21, 2026',
    document_action: 'Send us renewed proof of insurance for this car before the expiry date.',
    document_action_short: 'Send renewed proof before then to keep the listing live.',
    document_consequence: 'If we do not have renewed proof by the expiry date, we must pause the Turo listing until we do.',
  },
};
