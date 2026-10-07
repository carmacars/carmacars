import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_application_declined',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Vehicle onboarding status changes to declined at any step before enrolled. Staff choose the reason.',
  timing: 'Immediate',
  subject: 'We cannot enrol your {{vehicle_name}}',
  preheader: 'Here is why, and what it means for your other vehicles.',
  ref: 'Owner application',
  body: [
    hero('Application declined', 'We cannot enrol this vehicle', 'Sorry, {{first_name}}. We are not able to take the {{vehicle_name}} into the program.'),
    notice('info', 'Reason', '{{decline_reason}}'),
    p('This decision is about this vehicle only. Any other vehicle you have with us, or apply for, is looked at on its own.'),
    when('has_amount_paid', [
      p('You paid **{{amount_paid}}** for this vehicle. We will return it to you and confirm by email when it is sent.'),
    ]),
    button('Go to my owner account', '@owner'),
  ],
  sample: {
    vehicle_name: '2019 Nissan Rogue SV', decline_reason: 'The vehicle history shows a rebuilt brand, and branded vehicles cannot join the fleet policy.',
    has_amount_paid: false, amount_paid: '$0.00',
  },
};
