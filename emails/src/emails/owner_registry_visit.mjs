import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_registry_visit',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Vehicle onboarding status changes to registry_booked (Fleet booked the registry visit), and again if the date, time or place changes. (Message template T21.)',
  timing: 'Immediate',
  source: 'T21',
  subject: 'Registry visit booked: {{visit_date}} at {{visit_time}}',
  preheader: 'For your {{vehicle_name}}. Bring the items on this list.',
  ref: 'Vehicle onboarding',
  body: [
    hero('Registry visit', 'Your registry visit is booked', 'One of our admins will meet you there, {{first_name}}, to register your {{vehicle_name}}.'),
    keyfacts(
      { label: 'When', value: '{{visit_date}}', sub: '{{visit_time}}' },
      { label: 'Where', value: '{{visit_place}}' },
    ),
    h('Bring these'),
    table({ each: 'visit_items', cols: [{ head: 'Item', value: '{{name}}', strong: true }] }),
    notice('info', 'You pay at the counter', 'You pay the registry fees and any tax directly. Your estimate is {{onboarding_estimate}}. Amounts may vary.'),
    button('Open my onboarding checklist', '@owner_vehicle_onboarding'),
    small('If you cannot make it, reply to this email as soon as you can. The visit has to fall inside the {{safety_certificate_days}} days your safety certificate is valid.'),
  ],
  sample: {
    vehicle_name: '2023 Toyota RAV4 XLE', vehicle_id: 'v-3f81c2', visit_date: 'Thu, Nov 5, 2026', visit_time: '11:30 am',
    visit_place: 'ServiceOntario, 777 Bay Street, Toronto', onboarding_estimate: '$250 plus HST',
    visit_items: [
      { name: 'Your driver\'s licence' }, { name: 'Original ownership permit' }, { name: 'Proof of current insurance' },
      { name: 'Lender permission letter' }, { name: 'Safety standards certificate' },
    ],
  },
};
