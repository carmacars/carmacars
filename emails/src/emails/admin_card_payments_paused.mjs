import { hero, small, facts, notice, list, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'admin_card_payments_paused',
  audience: 'staff_admin',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'Hotfix 3650: the card processor reports that the account cannot take card payments (Stripe charges_enabled false), seen by the deposit guard or a Stripe account.updated event. Card payments are treated as off until it takes them again. Sent to the Admins once per pause (again only after it came back and paused again).',
  timing: 'Immediate',
  subject: 'Card payments are paused: renters pay by e-Transfer',
  preheader: '{{card_provider_name}} reports the account cannot take card payments. Booking and paying keep working by e-Transfer.',
  ref: 'System',
  body: [
    hero('Card payments paused', 'The card processor stopped taking payments', '{{card_provider_name}} reports that the account cannot take card payments ({{card_pause_reason}}). The site switched to e-Transfer by itself.'),
    notice('info', 'Booking and paying keep working', 'Renters see e-Transfer instructions with the exact amounts and upload the screenshot; Finance confirms each in one tap. Card links, card holds and Collect a card are paused for staff.'),
    facts(
      ['Since', '{{card_paused_at}}'],
      ['Card payments', '{{card_payments_text}}'],
      ['Payouts', '{{card_payouts_text}}'],
    ),
    list(
      'Check the account at the card processor and answer what it asks for.',
      'When it takes payments again, cards come back by themselves. To keep e-Transfer only, turn Card payments off in Program settings.',
    ),
    button('Open Program settings', '@admin_settings_program'),
    small('One email per pause. The To do on Today stays until cards work again.'),
  ],
  sample: {
    card_provider_name: 'Stripe', card_pause_reason: 'rejected.other', card_paused_at: 'Tue, Nov 24, 2026 at 2:10 pm',
    card_payments_text: 'Off', card_payouts_text: 'Off',
  },
};
