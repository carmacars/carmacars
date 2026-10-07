import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_vehicle_enrolled',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Vehicle onboarding status changes to enrolled (the insurer\'s confirmation is filed and the vehicle is on the fleet policy). This email is the written confirmation that sets the Enrollment Date. (Message template T22.)',
  timing: 'Immediate',
  source: 'T22',
  subject: 'Written confirmation: your {{vehicle_name}} is on the fleet policy',
  preheader: 'Enrollment Date {{enrollment_date}}. You may now cancel your own insurance on it.',
  ref: 'Enrollment confirmation',
  body: [
    hero('Enrolled', 'Your vehicle is on the CarmaCars fleet policy', 'This is your written confirmation, {{first_name}}. Keep it with your agreement.'),
    facts(
      ['Vehicle', '{{vehicle_name}}'],
      ['VIN', '{{vehicle_vin}}'],
      ['Plate', '{{vehicle_plate}}'],
      ['On the fleet policy from', '{{enrollment_date}}'],
      ['Enrollment Date', '{{enrollment_date}}'],
    ),
    notice('info', 'Your own insurance', 'You may now cancel your own insurance on this vehicle, effective {{enrollment_date}} or later. Not before.'),
    h('From here'),
    list(
      'Monthly fees start from the Enrollment Date and are charged on the 15th.',
      'We photograph and list the car. You get an email when it is live.',
      'You can see the car\'s live location in your owner account at any time.',
    ),
    button('Open my vehicle', '@owner_vehicle'),
  ],
  sample: {
    vehicle_name: '2023 Toyota RAV4 XLE', vehicle_id: 'v-3f81c2', vehicle_vin: '2T3P1RFV0PC000000', vehicle_plate: 'CXRV 310',
    enrollment_date: 'Mon, Nov 9, 2026',
  },
};
