import { hero, p, small, button, facts } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_schedule_ready',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Sign first (r50, migration 3800): cars an owner (or staff for them) added after the master agreement was signed are on Schedule A as new numbered entries, and the short schedule confirmation (the Additional Vehicle Schedule) waits for the owner\'s e-signature. Once per batch of cars added together; the government forms of each car are made at the same moment.',
  timing: 'Immediate',
  subject: 'Confirm {{car_count}} added to your Schedule A',
  preheader: '{{car_list}}. One signature confirms them.',
  ref: 'Schedule A',
  body: [
    hero('Step 3 of 6', 'Confirm your new cars', 'Hi {{first_name}}, these cars are on Schedule A of your {{agreement_title}} now. One signature confirms them; CarmaCars countersigns at the same moment.'),
    facts(
      ['Cars', '{{car_list}}'],
      ['Agreement', '{{agreement_title}} {{agreement_number}}'],
    ),
    button('Confirm the schedule', '{{sign_url}}'),
    p('A car is approved, delivered and rented only once its schedule entry is signed.'),
    small('A car listed by mistake? Reply to this email before you sign and we take it off.'),
  ],
  sample: { car_count: '2 cars', car_list: '2021 Toyota Camry (Q33A), 2020 Honda Civic (Q33B)', agreement_title: 'Fleet Supplier Lease Agreement', agreement_number: 'EA-1042', sign_url: 'https://carmacars.ca/owner/sign' },
};
