import { hero, facts, button, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_gift_card_sold',
  audience: 'staff_va_finance',
  also_sent_to: ['staff_admin'],
  category: 'transactional',
  from: FROM.billing,
  digest: true,
  digestSlot: 'next',
  trigger: 'Gift cards (migration 3600): a gift card or gifted rental was paid online, or an Admin issued a voucher credit. Queued for the next Finance and Admin digest.',
  timing: 'Next digest',
  subject: 'Gift card {{gift_kind}}: {{gift_amount}}',
  preheader: '{{buyer_name}} for {{recipient_name}}. Gift cards outstanding: {{outstanding_total}}.',
  ref: 'Gift card ending {{gift_code_last4}}',
  body: [
    hero('Gift cards', 'A gift card was {{gift_kind}}', '{{buyer_name}}, for {{recipient_name}}.'),
    facts(['Amount', '{{gift_amount}}'], ['Kind', '{{gift_type}}'], ['Card', 'Ending {{gift_code_last4}}'], ['Outstanding on all gift cards', '{{outstanding_total}}']),
    button('Open gift cards', '@va_finance_gift_cards'),
    small('A sold gift card is a liability until it is used: no HST and no revenue until it pays for a rental.'),
  ],
  sample: { gift_kind: 'sold', gift_amount: '$150.00', buyer_name: 'Sam Rivera', recipient_name: 'Jordan Lee', gift_type: 'Gift card', gift_code_last4: 'Q7XM', outstanding_total: '$2,430.00' },
};
