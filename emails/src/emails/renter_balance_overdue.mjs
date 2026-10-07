import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_balance_overdue',
  audience: 'renter',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'Daily check: a renter statement was sent 7 days ago and a balance on it is still unpaid (all card retries failed or are pending). Sent once at 7 days, then with each monthly interest posting on the 1st while a balance remains.',
  timing: '7 days after the statement, then monthly on the 1st',
  subject: 'Overdue: {{amount_due}} on booking {{booking_number}}',
  preheader: 'Interest of {{interest_rate}} a month now applies. Pay today to stop it.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Balance overdue', 'Your balance is now overdue', 'We sent your statement on {{statement_date}}, {{first_name}}, and the amount below is still unpaid.'),
    figure('Overdue', '{{amount_due}}', 'Includes interest to date of {{interest_to_date}}.'),
    notice('alert', 'Interest is being added', 'Overdue amounts carry interest of {{interest_rate}} a month, compounded monthly, until paid. Collection costs are billed at cost.'),
    button('Pay {{amount_due}} now', '@booking_pay'),
    p('If you cannot pay in full today, reply to this email or call us. We would rather agree a plan with you than send this further.'),
    link('View the statement and records', '@booking_statement'),
  ],
  sample: { statement_date: 'Wed, Nov 4, 2026', amount_due: '$80.57', interest_to_date: '$0.00', interest_rate: '1.5%' },
};
