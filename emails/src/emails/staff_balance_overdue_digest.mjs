import { hero, small, facts, notice, button, rows, when } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_balance_overdue_digest',
  audience: 'staff_va_finance',
  also: ['staff_admin'],
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'Every day at 9 am Toronto time (r49, app.job_r49_notices): the renter statements with a balance still unpaid after the overdue days (notify_balance_overdue_days), listed with the amount, the days overdue and the booking link. Sent only when at least one is overdue. A balance overdue 3 days or more also has an Admin To do (Renter balance overdue), once per statement.',
  timing: 'Daily, 9 am',
  subject: '{{overdue_count}} renter balances overdue, {{overdue_total}}',
  preheader: 'The renters who still owe a balance, with amounts and booking links.',
  ref: '{{overdue_date}}',
  body: [
    hero('Balances overdue', '{{overdue_count}} balances overdue: {{overdue_total}}', 'These renters were sent their statement and still owe a balance. Oldest first.'),
    rows('items', '{{booking_number}}  {{amount_due}}', '{{renter_name}}. {{days_overdue}} days overdue.', '{{url}}'),
    button('Open Money', '@va_finance_invoice'),
    small('Balances overdue 3 days or more are also on the Admin To do. The renter has had the pay link and the overdue email.'),
  ],
  sample: {
    overdue_count: '2', overdue_total: '$680.40', overdue_date: 'Mon, Nov 23, 2026',
    items: [
      { booking_number: 'CC-10482', amount_due: '$480.40', renter_name: 'Maya Okafor', days_overdue: '9', url: 'https://carmacars.ca/staff/bookings/CC-10482' },
      { booking_number: 'CC-10511', amount_due: '$200.00', renter_name: 'Sam Lee', days_overdue: '4', url: 'https://carmacars.ca/staff/bookings/CC-10511' },
    ],
  },
};
