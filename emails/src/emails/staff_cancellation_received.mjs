import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_cancellation_received',
  audience: 'staff_va_finance',
  also: ['staff_va_cs'],
  category: 'transactional',
  from: FROM.billing,
  digest: true,
  digestSlot: 'next',
  trigger: 'A booking cancellation row is created (booking status becomes cancelled or no_show). Queued for the next finance and customer service digests. Sent immediately to the admins instead when the refund is over $500 or outside the tier table, because it needs approval.',
  timing: 'Next digest. Immediate to admins when approval is needed',
  subject: 'Cancelled: {{booking_number}}, refund {{refund_amount}} to process',
  preheader: '{{renter_name}}, tier {{refund_percent}}. Refund due within 10 business days.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Cancellation', 'Booking {{booking_number}} was cancelled', '{{renter_name}} cancelled the {{vehicle_name}}. The calendar is free again.'),
    facts(
      ['Booking made', '{{booked_at}}'],
      ['Cancellation received', '{{cancellation_received_at}}'],
      ['Start', '{{pickup_date}}, {{pickup_time}}'],
      ['Tier', '{{refund_tier}}'],
      ['Refund', '{{refund_percent}} of {{amount_paid}} = {{refund_amount}}'],
      ['Deposit', '{{deposit_status}}'],
    ),
    button('Process the refund', '@va_finance_booking'),
    small('Target 2 business days, limit 10. Any refund outside the table, or over $500, needs an admin.'),
  ],
  sample: {
    booked_at: 'Mon, Oct 12, 2026 at 6:30 pm', cancellation_received_at: 'Tue, Oct 20, 2026 at 9:14 am', refund_tier: '48 hours or more before the start',
    refund_percent: '75%', refund_amount: '$351.71', deposit_status: 'Not taken yet',
  },
};
