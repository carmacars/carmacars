import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_application_received',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'An owner vehicle application is submitted (vehicle onboarding row created with status intake), for a first vehicle or an added vehicle.',
  timing: 'Immediate',
  subject: 'We have your application for the {{vehicle_name}}',
  preheader: 'We reply within 1 business day with your fees and cost estimate.',
  ref: 'Owner application',
  body: [
    hero('Application received', 'Thanks, {{first_name}}. We have your vehicle.', 'We are reviewing your {{vehicle_name}} now. You will hear from us within 1 business day.'),
    facts(
      ['Vehicle', '{{vehicle_name}}'],
      ['VIN', '{{vehicle_vin}}'],
      ['Plate', '{{vehicle_plate}}'],
      ['Held as', '{{ownership_summary}}'],
    ),
    h('What happens next'),
    steps(
      ['We review the vehicle', 'We confirm it can join the fleet policy. A vehicle with a rebuilt, salvage or irreparable brand cannot be enrolled.'],
      ['We send your terms', 'Your monthly fees and revenue share, and an estimate of the registry costs for your situation.'],
      ['You sign', 'The agreements are signed on the website. Nothing is owed until then.'],
    ),
    button('View my application', '@owner_application'),
    small('You can add or correct details on the same page until we send your terms.'),
  ],
  sample: {
    vehicle_name: '2023 Toyota RAV4 XLE', vehicle_vin: '2T3P1RFV0PC000000', vehicle_plate: 'CXRV 310',
    ownership_summary: 'Individual, financed',
  },
};
