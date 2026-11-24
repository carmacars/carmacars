import { hero, small, facts, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_etransfer_declined',
  audience: 'staff_va_sales',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'Release 49 (3610): Finance or an Admin pressed Not received on an e-Transfer a Sales rep reported (Check e-Transfer), with the reason. One email to the rep who reported it, at their own address. Nothing was recorded; the booking still waits for payment and the rep may report it again.',
  timing: 'Immediate',
  subject: 'e-Transfer not received: booking {{booking_number}}',
  preheader: '{{decided_by_name}}: {{decline_reason}}',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Not received', 'The e-Transfer is not in the bank', 'Hi {{first_name}}. {{decided_by_name}} checked the e-Transfer of {{etransfer_amount}} you reported on booking {{booking_number}} and did not find it.'),
    facts(
      ['Reason', '{{decline_reason}}'],
      ['Amount', '{{etransfer_amount}}'],
      ['Renter', '{{renter_name}}'],
      ['Report', '{{etransfer_number}}'],
    ),
    button('Open the booking', '@va_sales_booking_money'),
    small('The booking still waits for payment. Check with the renter, then report it again with the right amount or a clearer screenshot.'),
  ],
  sample: {
    decided_by_name: 'Grace Lim', decline_reason: 'Nothing from this sender in the bank yet', etransfer_amount: '$1,240.50', etransfer_number: 'ET-1001',
  },
};
