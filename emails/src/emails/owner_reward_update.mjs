import { hero, notice, when, button, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_reward_update',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Owner rewards (release 48, migration 3262), to an owner in the Vehicle Owner Program, once per event: a merch kit ready to redeem (6 months) or the premium kit (12 months); a kit redeemed (on our list to ship) and shipped; a free upgrade request received, approved (with its code) or declined (with the reason); the credit for referring an owner (once their car has been live 30 days); the birthday rental credit; a friend\'s rental confirmed with the owner\'s code; a credit added by an Admin. The type "Owner rewards" on the owner\'s Notifications tab switches it per channel.',
  timing: 'Immediate, once per event',
  subject: '{{reward_title}}',
  preheader: '{{reward_text}}',
  ref: 'Rewards',
  body: [
    hero('Rewards', '{{reward_title}}', 'Hi {{first_name}}. {{reward_text}}'),
    when('reward_detail', [notice('info', 'Good to know', '{{reward_detail}}')]),
    button('Open your rewards', '@owner_rewards'),
    small('Credits show as a line on your statement. Your Revenue Share and fees do not change.'),
  ],
  sample: {
    first_name: 'Daniel', reward_title: 'Your merch kit has shipped', reward_text: 'It is on its way to 12 Maple Street, Toronto.', reward_detail: 'Tracking: CP 1234 5678 9012',
  },
};
