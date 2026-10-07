import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_bank_details_changed',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'An owner\'s payout account, pre-authorized debit authorization or card on file is added, changed or removed, by the owner or by staff. Sent to the owner\'s email address on file before the change, and never batched. Security notice.',
  timing: 'Immediate',
  subject: 'Your CarmaCars payment details were changed',
  preheader: '{{change_summary}}. If this was not you, call us now.',
  ref: 'Security notice',
  body: [
    hero('Security notice', 'Your payment details were changed', 'We are telling you because money moves through these details, {{first_name}}.'),
    facts(
      ['What changed', '{{change_summary}}'],
      ['When', '{{changed_at}}'],
      ['Changed by', '{{changed_by}}'],
      ['Now on file', '{{details_on_file}}'],
    ),
    notice('alert', 'If this was not you', 'Call **{{support_phone}}** now so we can check the change with you before any money moves on it.'),
    button('Review my payment details', '@owner_billing'),
    small('If you made this change, there is nothing to do. We never ask for bank details by email, and we never show a full account number.'),
  ],
  sample: {
    change_summary: 'Payout account changed', changed_at: 'Tue, Nov 3, 2026 at 2:14 pm', changed_by: 'You, signed in from Toronto, Ontario',
    details_on_file: 'Account ending 6621',
  },
};
