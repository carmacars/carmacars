import { hero, facts, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_gift_card_voided',
  audience: 'staff_admin',
  also_sent_to: ['staff_va_finance'],
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'Gift cards (migration 3600): an Admin voided a gift card or voucher, with the reason. Sent at once to Admins and Finance.',
  timing: 'Immediate',
  subject: 'Gift card ending {{gift_code_last4}} voided',
  preheader: '{{amount_voided}} taken off by {{actor_name}}: {{void_reason}}',
  ref: 'Gift card ending {{gift_code_last4}}',
  body: [
    hero('Gift cards', 'A gift card was voided', '{{actor_name}} voided the card ending {{gift_code_last4}}.'),
    facts(['Balance taken off', '{{amount_voided}}'], ['Reason', '{{void_reason}}'], ['Kind', '{{gift_type}}']),
    button('Open gift cards', '@admin_gift_cards'),
  ],
  sample: { gift_code_last4: 'Q7XM', amount_voided: '$150.00', actor_name: 'Abbas', void_reason: 'Paid with a stolen card (Stripe dispute)', gift_type: 'Gift card' },
};
