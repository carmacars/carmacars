import { hero, small, table, figure, facts, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_commission_paid',
  audience: 'staff_va_sales',
  also: ['staff_va_cs', 'staff_va_finance', 'staff_va_fleet', 'staff_field'],
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'An Admin records the payment of a staff member\'s approved commissions (Admin > Money > Staff commissions > Record a payment): e-Transfer, bank transfer, Wise, cash, another way, or the monthly pay statement. One email to that staff member, at their own address, for each payment recorded.',
  timing: 'Immediate',
  subject: 'Commission paid: {{commission_total}}',
  preheader: '{{payout_method}}, {{payout_date}}.',
  ref: 'Commissions',
  body: [
    hero('Commission paid', 'Your commission is paid', 'Hi {{first_name}}. We recorded the payment of the commissions below.'),
    figure('Paid', '{{commission_total}}', '{{commission_count}} line(s), clawbacks included'),
    facts(
      ['How', '{{payout_method}}'],
      ['Date', '{{payout_date}}'],
      { label: 'Reference', value: '{{payout_reference}}', when: 'payout_reference' },
    ),
    table({
      each: 'commissions',
      cols: [
        { head: 'Booking', value: '{{booking}}', strong: true },
        { head: 'Month', value: '{{month}}' },
        { head: 'Rate', value: '{{what}}' },
        { head: 'Amount', value: '{{amount}}', align: 'right', strong: true },
      ],
    }),
    button('See your commissions', '{{sales_url}}'),
    small('If something looks wrong, reply to this email.'),
  ],
  sample: {
    commission_total: '$184.50', commission_count: '3', payout_method: 'e-Transfer', payout_date: 'November 5, 2026', payout_reference: 'CA7xQ2',
    commissions: [
      { booking: 'CC-10482', month: 'October 2026', what: '15%', amount: '$90.00' },
      { booking: 'CC-10497', month: 'October 2026', what: '15%', amount: '$63.00' },
      { booking: 'CC-10511', month: 'October 2026', what: '15%', amount: '$31.50' },
    ],
    sales_url: 'https://carmacars.ca/va/my-sales',
  },
};
