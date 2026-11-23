import { hero, p, figure, button, link } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_gift_card_sent',
  audience: 'renter',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'Gift cards (migration 3600): a gift card the buyer scheduled for a later date was emailed to the recipient on that date. Sent to the buyer once. Not sent when the gift went at once (the receipt says so).',
  timing: 'On the send date',
  subject: 'Your gift card reached {{recipient_name}}',
  preheader: 'We emailed {{gift_amount}} to {{recipient_email}} today.',
  ref: 'Gift card ending {{gift_code_last4}}',
  body: [
    hero('Gift card', 'Your gift is on its way', 'We emailed your gift card to {{recipient_name}} today, {{first_name}}.'),
    figure('Sent', '{{gift_amount}}', 'To {{recipient_email}}.'),
    p('If it does not arrive, ask them to check their junk folder, or reply to this email and we will send it again.'),
    button('See my gift cards', '@account_gift_cards'),
    link('Send another gift card', '@gift_cards'),
  ],
  sample: { recipient_name: 'Jordan Lee', recipient_email: 'jordan@example.test', gift_amount: '$150.00', gift_code_last4: 'Q7XM' },
};
