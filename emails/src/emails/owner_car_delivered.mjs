import { hero, small, button, facts } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_car_delivered',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Sign first (r50, migration 3800): a fleet supplier\'s car is approved and goes on the lease (app.fleet_lease_car_set), by an Admin or by itself when the supplier signed after an Admin approved it. Once per car.',
  timing: 'Immediate',
  subject: 'Approved: your {{vehicle_name}} is on the lease from {{delivered_on}}',
  preheader: '{{tier}} car, {{monthly_amount}} a month. First payment {{first_payment_on}}.',
  ref: 'Fleet lease',
  body: [
    hero('Step 6 of 6', 'Your {{vehicle_name}} is on the lease', 'Hi {{first_name}}, it is approved and leased to CarmaCars from {{delivered_on}}. Hand it over as agreed.'),
    facts(
      ['Car', '{{vehicle_name}}'],
      ['Tier', '{{tier}}'],
      ['Lease', '{{monthly_amount}} a month'],
      ['First payment', '{{first_payment_on}}, in arrears'],
    ),
    button('Open your lease', '@owner'),
    small('No fees: you never get an invoice or a debit for a leased car.'),
  ],
  sample: { vehicle_name: '2021 Toyota Camry', tier: 'Regular', monthly_amount: '$580.00', delivered_on: 'Tue, Nov 24, 2026', first_payment_on: 'Thu, Jan 10, 2027' },
};
