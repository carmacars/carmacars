import { hero, small, table, figure, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_commission_approved',
  audience: 'staff_va_sales',
  also: ['staff_va_cs', 'staff_va_finance', 'staff_va_fleet', 'staff_field'],
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'An Admin approves one or more of a staff member\'s commissions (Admin > Money > Staff commissions). One email to that staff member, at their own address, for each approval. A Sales commission is approved after its month ends. Nothing is paid yet: the payment is recorded separately.',
  timing: 'Immediate',
  subject: 'Commission approved: {{commission_total}}',
  preheader: '{{commission_count}} commission(s) approved. You will hear from us again when it is paid.',
  ref: 'Commissions',
  body: [
    hero('Commission approved', 'Your commission is approved', 'Hi {{first_name}}. An Admin approved the commissions below. They are paid by hand, on your pay statement or by transfer, and we will email you when that is done.'),
    figure('Approved', '{{commission_total}}', '{{commission_count}} commission(s)'),
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
    small('A refund or chargeback after a commission is paid is taken off a later payment. Questions: reply to this email.'),
  ],
  sample: {
    commission_total: '$184.50', commission_count: '3',
    commissions: [
      { booking: 'CC-10482', month: 'October 2026', what: '15%', amount: '$90.00' },
      { booking: 'CC-10497', month: 'October 2026', what: '15%', amount: '$63.00' },
      { booking: 'CC-10511', month: 'October 2026', what: '15%', amount: '$31.50' },
    ],
    sales_url: 'https://carmacars.ca/va/my-sales',
  },
};
