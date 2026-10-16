import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_exit_notice_received',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Vehicle status changes to exit_notice (the owner\'s written notice naming the vehicle is logged, or an admin decides to remove it) and the Exit Date is set. This email confirms the Exit Date in writing.',
  timing: 'Immediate',
  subject: 'Exit notice received for your {{vehicle_name}}. Exit Date {{exit_date}}',
  preheader: 'What happens between now and then, and what we need from you.',
  ref: 'Vehicle exit',
  body: [
    hero('Exit notice', 'We have your notice. Exit Date: {{exit_date}}', 'This confirms the exit of your {{vehicle_name}} in writing, {{first_name}}. Your other vehicles carry on as they are.'),
    facts(
      ['Notice received', '{{notice_date}}'],
      ['Exit Date', '{{exit_date}}'],
      ['How it is set', '{{exit_date_basis}}'],
      ['Transfer-back fees', '{{retransfer_fee_note}}'],
    ),
    h('What happens'),
    steps(
      ['We stop new bookings after the Exit Date', 'Bookings already confirmed before that date go ahead.'],
      ['You send proof of your own insurance', 'It must start on the Exit Date. We need it before we hand the car back.'],
      ['On the Exit Date', 'We remove the tracker, record the odometer and photos, and take the car off the fleet policy.'],
      ['Registration goes back to you', 'We complete our part within {{retransfer_business_days}} business days after the Exit Date. We both sign Form E and you get the car, keys and permit.'],
      ['Final account', 'The last month\'s fees are pro-rated to the Exit Date. Your final balance is paid on the first payout date after the month of the Exit Date.'],
    ),
    button('Upload my proof of insurance', '@owner_vehicle_exit'),
    small('Getting your car back is never delayed because money is owed.'),
  ],
  sample: {
    notice_date: 'Mon, Nov 2, 2026', exit_date: 'Wed, Dec 2, 2026', exit_date_basis: '30 days from your notice. No rental runs past that date.',
    retransfer_fee_note: 'Paid by you. The car has been on the fleet policy for less than 6 months.',
  },
};
