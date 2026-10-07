import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_fleet_count_warning',
  audience: 'staff_admin',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Fleet-recount job (Monday 08:00): vehicles on the fleet policy, less those under exit notice, number 11 or fewer. Also sent at once when an exit notice or removal would take the count to 11 or fewer. Turo-Only cars are not counted.',
  timing: 'Monday 08:00, or at once on an exit notice',
  subject: 'Fleet count is {{fleet_count}}. The minimum is 10',
  preheader: '{{fleet_exiting}} under exit notice. Count after exits: {{fleet_count_after}}.',
  ref: 'Fleet count',
  body: [
    hero('Fleet warning', 'The fleet is close to its minimum', 'The fleet policy needs 10 or more vehicles at all times.'),
    keyfacts(
      { label: 'On the policy now', value: '{{fleet_count}}' },
      { label: 'After exits', value: '{{fleet_count_after}}' },
    ),
    facts(
      ['Under exit notice', '{{fleet_exiting}}'],
      ['Next Exit Date', '{{next_exit_date}}'],
      ['In onboarding', '{{fleet_onboarding}}'],
    ),
    button('Open the fleet register', '@admin_fleet'),
    small('Turo-Only cars are not counted. The monthly report to the franchisor goes out on the 1st.'),
  ],
  sample: { fleet_count: '11', fleet_count_after: '10', fleet_exiting: '1', next_exit_date: 'Wed, Dec 2, 2026', fleet_onboarding: '2 vehicles, earliest enrollment about Nov 20' },
};
