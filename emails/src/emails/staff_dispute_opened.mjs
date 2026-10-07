import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_dispute_opened',
  audience: 'staff_admin',
  also: ['staff_va_finance'],
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'A dispute row is created from the payment processor webhook (a card dispute or chargeback is opened on a renter payment, or a debit dispute on an owner invoice). Sent to both admins and finance. Immediate.',
  timing: 'Immediate',
  subject: 'DISPUTE: {{amount}} on booking {{booking_number}}, answer by {{evidence_due}}',
  preheader: '{{renter_name}}. Reason given: {{dispute_reason}}.',
  ref: 'Dispute {{dispute_id}}',
  body: [
    hero('Chargeback opened', 'A payment is being disputed', 'The cardholder\'s bank has opened a dispute. The amount stays owed while we contest it.'),
    figure('Disputed', '{{amount}}', 'Evidence is due by {{evidence_due}}.'),
    facts(
      ['Booking', '{{booking_number}}, {{vehicle_name}}'],
      ['Renter', '{{renter_name}}'],
      ['Payment', '{{payment_reason}}, paid {{payment_date}}'],
      ['Bank\'s reason', '{{dispute_reason}}'],
      ['Owner Revenue in dispute', '{{owner_revenue_in_dispute}}, withheld from the payout'],
    ),
    button('Open the dispute', '@admin_dispute'),
    h('Evidence to send'),
    list('Signed agreement and consents', 'Condition reports, pickup and return', 'Tracker data for the rental period', 'The statement and its supporting records'),
    small('A debit dispute on an owner invoice cannot be contested.'),
  ],
  sample: {
    dispute_id: 'dp_1Q8x2', amount: '$468.95', evidence_due: 'Mon, Nov 9, 2026', dispute_reason: 'Product not received',
    payment_reason: 'Booking total', owner_revenue_in_dispute: '$340.00',
  },
};
