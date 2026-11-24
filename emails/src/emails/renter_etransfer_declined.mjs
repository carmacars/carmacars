import { hero, small, facts, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_etransfer_declined',
  audience: 'renter',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'Hotfix 3650: Finance or an Admin pressed Not received on an e-Transfer the renter reported, with the reason. Nothing was recorded; the renter can send it again or upload a clearer screenshot. Once per report.',
  timing: 'Immediate',
  subject: 'We have not found your e-Transfer yet: booking {{booking_number}}',
  preheader: '{{decline_reason}}',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('e-Transfer not found', 'We could not find it yet', 'Hi {{first_name}}. We checked for your e-Transfer of {{etransfer_amount}} on booking {{booking_number}} and did not find it.'),
    facts(
      ['Why', '{{decline_reason}}'],
      ['Amount', '{{etransfer_amount}}'],
      ['Send to', '{{e_transfer_email}}'],
      ['Message', '{{booking_number}}'],
    ),
    button('Upload it again', '@booking_pay'),
    small('If you already sent it, upload the confirmation screenshot again from your booking, or reply to this email.'),
  ],
  sample: { etransfer_amount: '$1,240.50', decline_reason: 'Nothing from this sender in the bank yet', e_transfer_email: 'pay@carmacars.ca' },
};
