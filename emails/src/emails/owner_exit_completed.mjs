import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_exit_completed',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Vehicle status changes from exit_notice to exited (Form E signed by both sides, tracker removed, registration returned).',
  timing: 'Immediate',
  subject: 'Exit complete: your {{vehicle_name}} is back with you',
  preheader: 'Tracker removed, registration returned. Final statement on {{final_payout_date}}.',
  ref: 'Vehicle exit',
  body: [
    hero('Exit complete', 'Your {{vehicle_name}} has left the program', 'Everything on our side is done, {{first_name}}. Thank you for having your car with us.'),
    facts(
      ['Exit Date', '{{exit_date}}'],
      ['Tracker', 'Removed'],
      ['Fleet policy', 'Car removed. Your own insurance applies from the Exit Date.'],
      ['Registration', '{{retransfer_summary}}'],
      ['Form E', 'Signed by both sides'],
    ),
    h('Money still to settle'),
    list(
      'Your prepaid last month\'s insurance fee pays the exit month, pro-rated to the Exit Date. The unused part is refunded.',
      'The tracker fee for the exit month is billed pro-rated.',
      'Your final statement and balance are paid on **{{final_payout_date}}**.',
    ),
    button('Download my exit documents', '{{signed_agreement_url}}'),
    small('The download link works for 7 days. Your documents stay in [your owner account](@owner_documents).'),
  ],
  sample: { exit_date: 'Wed, Dec 2, 2026', retransfer_summary: 'CarmaCars removed as co-registrant on Dec 4, 2026', final_payout_date: 'January 10, 2027' },
};
