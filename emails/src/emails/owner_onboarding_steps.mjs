import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_onboarding_steps',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Vehicle onboarding status changes to upfront_paid (or straight from documents_signed for a shareholder-owned vehicle). Lists the steps and documents for that vehicle\'s onboarding method.',
  timing: 'Immediate',
  subject: 'Next steps to enrol your {{vehicle_name}}',
  preheader: 'What to get, what to bring, and what the registry will cost you.',
  ref: 'Vehicle onboarding',
  body: [
    hero('Onboarding steps', 'Here is the path to a live car', 'Thanks for your payment, {{first_name}}. These are the steps for your {{vehicle_name}}, in order.'),
    facts(
      ['Registration method', '{{onboarding_method}}'],
      ['Your estimate', '{{onboarding_estimate}}, paid by you directly to the registry'],
      ['Government forms', '{{government_forms}}'],
    ),
    notice('info', 'About the estimate', 'It is an estimate only and may vary. You pay ServiceOntario, the safety inspection and any appraisal directly, at the counter or to the shop. CarmaCars does not collect these amounts.'),
    h('Your steps'),
    steps(
      ['Get what your method needs', '{{owner_to_obtain}}'],
      ['We prepare the forms and book the registry visit', 'We fill in the government forms and send you the date, time and place. A safety certificate is valid for 36 days, so we book inside that window.'],
      ['Registry visit', 'You attend with one of our admins and pay the registry fees and any tax at the counter.'],
      ['Tracker install', 'Our field staff fit the tracker and we test it with the car parked. You get access to live location.'],
      ['Fleet policy', 'We add the car to the CarmaCars fleet policy and send you written confirmation. That date is your Enrollment Date.'],
    ),
    h('Documents to upload now'),
    table({ each: 'documents_needed', cols: [{ head: 'Document', value: '{{name}}', strong: true }, { head: 'Status', value: '{{status}}' }] }),
    button('Open my onboarding checklist', '@owner_vehicle_onboarding'),
    notice('alert', 'Keep your own insurance for now', 'Do not cancel it until we confirm in writing that the car is on the fleet policy.'),
  ],
  sample: {
    vehicle_name: '2023 Toyota RAV4 XLE', vehicle_id: 'v-3f81c2', onboarding_method: 'Co-Registrant',
    onboarding_estimate: '$250 plus HST', government_forms: 'SR-LV-006, SR-LV-012',
    owner_to_obtain: 'A safety standards certificate from a licensed inspection station, and written permission from your lender. You arrange and pay for both.',
    documents_needed: [
      { name: 'Ownership permit', status: 'Received' },
      { name: 'Proof of current insurance', status: 'Received' },
      { name: 'Lender permission letter', status: 'Needed' },
      { name: 'Safety standards certificate', status: 'Needed' },
    ],
  },
};
