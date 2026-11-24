import { hero, small, facts, button, notice } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_etransfer_reported',
  audience: 'staff_va_finance',
  also: ['staff_admin'],
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'Release 49 (3610): a Sales rep reports on a booking waiting for payment that the renter sent an e-Transfer (Renter sent an e-Transfer, with the amount, what it covers, the sender and a screenshot). Nothing is recorded: a Check e-Transfer To do is raised for Finance and the Admins. Immediate, once per report, to Finance and the Admins.',
  timing: 'Immediate',
  subject: 'Check e-Transfer: {{etransfer_amount}} on booking {{booking_number}}',
  preheader: '{{reporter_name}} says {{renter_name}} sent it for {{etransfer_covers}}. Confirm it once it is in the bank.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Check e-Transfer', '{{etransfer_amount}} on {{booking_number}}', '{{reporter_name}} reported that {{renter_name}} sent an e-Transfer. Nothing is recorded until you confirm it is in the bank.'),
    facts(
      ['Amount', '{{etransfer_amount}}'],
      ['Covers', '{{etransfer_covers}}'],
      ['Sender', '{{etransfer_sender}}'],
      ['Reported by', '{{reporter_name}}'],
      ['Report', '{{etransfer_number}}'],
    ),
    button('Check the e-Transfer', '@va_finance_booking_money'),
    notice('info', 'One tap', 'Confirm received records the payment and confirms the booking. Not received sends it back to the rep with your reason.'),
    small('The screenshot is on the booking, under Money.'),
  ],
  sample: {
    etransfer_amount: '$1,240.50', etransfer_covers: 'the rental and the deposit', etransfer_sender: 'Maya Okafor',
    reporter_name: 'Marco Reyes', etransfer_number: 'ET-1001',
  },
};
