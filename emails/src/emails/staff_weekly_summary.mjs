import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_weekly_summary',
  audience: 'staff_admin',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'Scheduled: every Monday at 07:45 Toronto time, for the week that ended Sunday at midnight. One email to each of the two admins. Always sent, even with no activity.',
  timing: 'Monday 07:45',
  subject: 'Week of {{week_label}}: {{bookings_confirmed}} bookings, {{revenue_collected}} collected',
  preheader: 'Utilization {{utilization}}. {{overdue_count}} overdue items need a decision.',
  ref: 'Weekly summary',
  body: [
    hero('Weekly summary', 'Week of {{week_label}}', 'Good morning, {{first_name}}. Here is last week across the fleet, with the week before for comparison.'),
    keyfacts(
      { label: 'Bookings confirmed', value: '{{bookings_confirmed}}', sub: '{{bookings_change}}' },
      { label: 'Collected', value: '{{revenue_collected}}', sub: '{{revenue_change}}' },
    ),
    keyfacts(
      { label: 'Utilization', value: '{{utilization}}', sub: '{{utilization_change}}' },
      { label: 'Overdue items', value: '{{overdue_count}}', sub: 'Need a decision' },
    ),
    h('The week in numbers'),
    table({
      each: 'weekly_metrics',
      cols: [
        { head: 'Measure', value: '{{label}}' },
        { head: 'Last week', value: '{{value}}', align: 'right', strong: true },
        { head: 'Week before', value: '{{previous}}', align: 'right' },
      ],
    }),
    h('Overdue'),
    rows('overdue_items', '{{line}}', '{{meta}}', '{{url}}'),
    h('Coming up this week'),
    list('{{upcoming_1}}', '{{upcoming_2}}', '{{upcoming_3}}'),
    button('Open the weekly report', '@admin_weekly'),
    small('Utilization is rented days divided by available days, for vehicles on the fleet policy. Collected means money received, HST included, net of refunds.'),
  ],
  sample: {
    week_label: 'Oct 19 to 25', bookings_confirmed: '14', bookings_change: 'Up 3 on the week before', revenue_collected: '$9,842.10',
    revenue_change: 'Up $1,460.00', utilization: '61%', utilization_change: 'Up 6 points', overdue_count: '3',
    weekly_metrics: [
      { label: 'Requests received', value: '23', previous: '19' },
      { label: 'Offers sent', value: '19', previous: '16' },
      { label: 'Offers approved and paid', value: '14', previous: '11' },
      { label: 'Offers expired', value: '3', previous: '4' },
      { label: 'Median time to offer', value: '38 min', previous: '52 min' },
      { label: 'Rental charge (Owner Revenue base)', value: '$7,120.00', previous: '$6,050.00' },
      { label: 'Company-only fees', value: '$1,590.00', previous: '$1,368.00' },
      { label: 'Refunds', value: '$351.71', previous: '$0.00' },
      { label: 'Returns completed', value: '12', previous: '10' },
      { label: 'Late returns', value: '1', previous: '0' },
      { label: 'Incidents opened', value: '1', previous: '0' },
      { label: 'Vehicles on the fleet policy', value: '13', previous: '13' },
    ],
    overdue_items: [
      { line: 'Deposit not released: booking CC-10431', meta: '8 business days since check-in. Limit is 7.', url: 'https://carmacars.ca/admin/bookings/CC-10431' },
      { line: 'Charge unpaid: booking CC-10418, $80.57', meta: 'Declined twice. Next retry Thu.', url: 'https://carmacars.ca/admin/bookings/CC-10418' },
      { line: 'Owner in arrears: 2022 Hyundai Elantra Preferred', meta: '$586.75 since Nov 18. Deduct at the Dec 10 payout.', url: 'https://carmacars.ca/admin/approvals' },
    ],
    upcoming_1: '9 pickups and 11 returns booked.', upcoming_2: 'Owner statements draft on the 5th. Approve by the 9th.', upcoming_3: '1 registry visit: Thu at 11:30 am',
  },
};
